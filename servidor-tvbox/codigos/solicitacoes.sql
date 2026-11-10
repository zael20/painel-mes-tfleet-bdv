-- =====================================================================
-- QUADRO DE SOLICITAÇÕES A FORNECEDORES  (página docs/solicitacoes.html)
-- Rodar inteiro no Supabase → SQL Editor → New query → Run.
-- Pode rodar de novo sem perder dados (só recria as funções).
--
-- Quem entra:
--   * Interno: a MESMA senha pessoal da Central (administrador, ou quem tiver
--     o painel "solicitacoes" nas permissões). Vê e edita todos os cartões.
--   * Fornecedor: senha criada no próprio quadro (menu Acessos). Vê e atualiza
--     só os cartões do fornecedor dele (ex.: TFleet).
-- Aviso por e-mail: Apps Script (solicitacoes-aviso.gs) chama sol_avisos com a
--   "chave do robô" (vista no quadro em Acessos → Aviso por e-mail).
-- Depende de: central-acessos.sql (já rodado).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- tabelas
create table if not exists public.sol_cartoes (
  id             bigserial primary key,
  fornecedor     text not null,
  assunto        text not null,
  descricao      text,
  link           text,
  responsavel    text,                       -- pessoa no fornecedor que cuida
  status         text not null default 'Enviado'
                 check (status in ('Enviado','Assumido','Em andamento','Entregue','Sem resposta','Cancelado')),
  enviado_em     date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  inicio_em      date,                       -- dia em que começaram a mexer
  prazo          date,
  prazo_original date,                       -- 1º prazo combinado (para ver se mudou)
  entregue_em    date,
  ultimo_contato date,
  emails         text[] not null default '{}',
  ultimo_aviso   date,
  ultimo_motivo  text,
  ordem          double precision not null default 0,
  criado_por     text,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

alter table public.sol_cartoes add column if not exists
  chave_publica text unique default encode(extensions.gen_random_bytes(12), 'hex');   -- link "só ver"

create table if not exists public.sol_historico (
  id         bigserial primary key,
  cartao_id  bigint not null references public.sol_cartoes(id) on delete cascade,
  ts         timestamptz not null default now(),
  quem       text,
  tipo       text not null,       -- criou, status, editou, comentario, aviso
  texto      text,
  dados      jsonb
);
create index if not exists sol_historico_cartao on public.sol_historico (cartao_id, ts desc);

create table if not exists public.sol_pessoas (          -- acessos de fornecedor
  id          bigserial primary key,
  nome        text not null,
  fornecedor  text not null,
  email       text,
  senha_hash  text not null unique,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now(),
  ultimo_acesso timestamptz
);

create table if not exists public.sol_sessoes (
  token      text primary key,
  pessoa_id  bigint not null references public.sol_pessoas(id) on delete cascade,
  expira_em  timestamptz not null
);

create table if not exists public.sol_sessoes_gestor (   -- entrou com a senha de gestores (Lotação)
  token      text primary key,
  expira_em  timestamptz not null
);

create table if not exists public.sol_config (
  id                int primary key default 1 check (id = 1),
  chave_robo        text not null default encode(extensions.gen_random_bytes(18), 'hex'),
  dias_sem_resposta int not null default 5,
  link_quadro       text not null default 'https://gestao-integrada.github.io/demandas/'
);
insert into public.sol_config (id) values (1) on conflict (id) do nothing;

alter table public.sol_cartoes   enable row level security;   -- sem policy: só pelas funções
alter table public.sol_historico enable row level security;
alter table public.sol_pessoas   enable row level security;
alter table public.sol_sessoes   enable row level security;
alter table public.sol_config    enable row level security;
alter table public.sol_sessoes_gestor enable row level security;
revoke all on public.sol_sessoes_gestor from anon, authenticated;
revoke all on public.sol_cartoes, public.sol_historico, public.sol_pessoas, public.sol_sessoes, public.sol_config
  from anon, authenticated;

-- ---------------------------------------------------------------- auxiliares (internas)
create or replace function public._sol_hoje() returns date
language sql stable as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

-- Quem é o dono do token: {nome, tipo: interno|fornecedor, fornecedor, admin}
create or replace function public._sol_quem(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a central_acessos; p sol_pessoas;
begin
  if p_token like 'tfs_%' then
    select * into a from public._central_pessoa(p_token);
    if a.id is not null and (a.admin or coalesce(a.perms, '{}'::jsonb) ? 'solicitacoes') then
      return jsonb_build_object('nome', a.nome, 'tipo', 'interno', 'fornecedor', null,
        'admin', a.admin, 'edita', a.admin or coalesce(a.perms->'solicitacoes', '[]'::jsonb) ? 'editar');
    end if;
  elsif p_token like 'tfg_%' then
    if exists (select 1 from sol_sessoes_gestor where token = p_token and expira_em > now()) then
      return jsonb_build_object('nome', 'Senha de gestores', 'tipo', 'interno', 'fornecedor', null,
        'admin', true, 'edita', true);
    end if;
  elsif p_token like 'tfq_%' then
    select pe.* into p from sol_sessoes s join sol_pessoas pe on pe.id = s.pessoa_id
     where s.token = p_token and s.expira_em > now() and pe.ativo;
    if p.id is not null then
      update sol_pessoas set ultimo_acesso = now() where id = p.id;
      if p.fornecedor = '*' then     -- acesso interno (pessoa da casa): vê e edita tudo, sem administrar
        return jsonb_build_object('nome', p.nome, 'tipo', 'interno', 'fornecedor', null, 'admin', false, 'edita', true);
      end if;
      return jsonb_build_object('nome', p.nome, 'tipo', 'fornecedor', 'fornecedor', p.fornecedor,
        'admin', false, 'edita', true);
    end if;
  end if;
  return null;
end $$;

create or replace function public._sol_exige(p_token text, p_admin boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_quem(p_token);
begin
  if q is null then raise exception 'sessao' using errcode = '28000'; end if;
  if p_admin and not (q->>'admin')::boolean then raise exception 'Só o administrador pode fazer isso.'; end if;
  return q;
end $$;

-- Situação do cartão (mesma regra do aviso por e-mail)
create or replace function public._sol_situacao(c public.sol_cartoes) returns text
language sql stable as $$
  select case
    when c.status = 'Entregue'  then 'entregue'
    when c.status = 'Cancelado' then 'cancelado'
    when c.prazo is not null and c.prazo <  public._sol_hoje() then 'vencido'
    when c.prazo is not null and c.prazo =  public._sol_hoje() then 'vence_hoje'
    when c.prazo is not null and c.prazo =  public._sol_hoje() + 1 then 'vence_amanha'
    when c.prazo is null and public._sol_hoje() - coalesce(c.ultimo_contato, c.enviado_em)
         >= (select dias_sem_resposta from public.sol_config where id = 1) then 'sem_resposta'
    when c.prazo is not null then 'no_prazo'
    else 'sem_prazo' end
$$;

create or replace function public._sol_json(c public.sol_cartoes, p_emails boolean) returns jsonb
language sql stable as $$
  select (to_jsonb(c) - 'ultimo_aviso' - 'ordem' - case when p_emails then 'x' else 'emails' end)
    || jsonb_build_object('situacao', public._sol_situacao(c),
         'dias_sem_contato', public._sol_hoje() - coalesce(c.ultimo_contato, c.enviado_em),
         'dias_para_prazo', case when c.prazo is not null then c.prazo - public._sol_hoje() end,
         'comentarios', (select count(*) from public.sol_historico h where h.cartao_id = c.id and h.tipo = 'comentario'))
$$;

revoke execute on function public._sol_quem(text), public._sol_exige(text, boolean)
  from public, anon, authenticated;

-- ---------------------------------------------------------------- entrar / sessão / sair
create or replace function public.sol_entrar(p_senha text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a central_acessos; p sol_pessoas; tk text;
begin
  if (select count(*) from central_acessos_log where evento = 'senha_errada' and painel = 'solicitacoes'
      and ts > now() - interval '10 minutes') >= 30 then
    return json_build_object('erro', 'Muitas tentativas erradas. Espere 10 minutos.');
  end if;
  -- 1) senha pessoal da Central
  select * into a from central_acessos where senha_hash = public._central_hash(trim(p_senha)) and ativo;
  if a.id is not null then
    if not (a.admin or coalesce(a.perms, '{}'::jsonb) ? 'solicitacoes') then
      return json_build_object('erro', 'Sua senha não tem acesso ao quadro de solicitações.');
    end if;
    tk := 'tfs_' || encode(gen_random_bytes(24), 'hex');
    insert into central_sessoes (token, acesso_id, expira_em) values (tk, a.id, now() + interval '30 days');
    perform public._central_log(a.id, a.nome, 'entrou', 'solicitacoes', 'Entrou no quadro de solicitações');
    return (jsonb_build_object('token', tk) || public._sol_quem(tk))::json;
  end if;
  -- 2) senha de fornecedor
  select * into p from sol_pessoas where senha_hash = public._central_hash('sol:' || trim(p_senha)) and ativo;
  if p.id is not null then
    tk := 'tfq_' || encode(gen_random_bytes(24), 'hex');
    insert into sol_sessoes (token, pessoa_id, expira_em) values (tk, p.id, now() + interval '60 days');
    delete from sol_sessoes where expira_em < now();
    perform public._central_log(null, p.nome || ' (' || p.fornecedor || ')', 'entrou', 'solicitacoes',
      'Fornecedor entrou no quadro');
    return (jsonb_build_object('token', tk) || public._sol_quem(tk))::json;
  end if;
  -- 3) senha de gestores (a mesma da Lotação)
  if exists (select 1 from lotacao_admin where id = 1 and senha_hash = crypt(trim(p_senha), senha_hash)) then
    tk := 'tfg_' || encode(gen_random_bytes(24), 'hex');
    insert into sol_sessoes_gestor (token, expira_em) values (tk, now() + interval '30 days');
    delete from sol_sessoes_gestor where expira_em < now();
    perform public._central_log(null, 'Senha de gestores', 'entrou', 'solicitacoes', 'Entrou no quadro de solicitações');
    return (jsonb_build_object('token', tk) || public._sol_quem(tk))::json;
  end if;
  perform public._central_log(null, null, 'senha_errada', 'solicitacoes');
  return json_build_object('erro', case when trim(p_senha) = '8015'
    then 'O código geral 8015 não vale aqui. Use sua senha pessoal da Central ou a senha de gestores.'
    else 'Senha incorreta.' end);
end $$;

create or replace function public.sol_sessao(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_quem(p_token);
begin
  if q is null then return json_build_object('erro', 'sessao'); end if;
  return q::json;
end $$;

create or replace function public.sol_sair(p_token text) returns text
language plpgsql security definer set search_path = public as $$
begin
  delete from sol_sessoes where token = p_token;
  delete from sol_sessoes_gestor where token = p_token;
  -- sessão da Central é a mesma da Central: não apaga aqui (a pessoa continua logada lá)
  return 'ok';
end $$;

-- ---------------------------------------------------------------- cartões
create or replace function public.sol_listar(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token);
begin
  return coalesce((select json_agg(public._sol_json(c, q->>'tipo' = 'interno') order by c.ordem, c.id)
    from sol_cartoes c
    where q->>'tipo' = 'interno' or lower(c.fornecedor) = lower(q->>'fornecedor')), '[]'::json);
end $$;

create or replace function public.sol_cartao(p_token text, p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); c sol_cartoes;
begin
  select * into c from sol_cartoes where id = p_id;
  if c.id is null or (q->>'tipo' = 'fornecedor' and lower(c.fornecedor) <> lower(q->>'fornecedor')) then
    raise exception 'Cartão não encontrado.';
  end if;
  return json_build_object('cartao', public._sol_json(c, q->>'tipo' = 'interno'),
    'historico', coalesce((select json_agg(h order by h.ts desc) from
      (select ts, quem, tipo, texto, dados from sol_historico where cartao_id = p_id) h), '[]'::json));
end $$;

-- Cria (p_id null) ou altera um cartão. p_dados = só os campos que mudam.
-- Fornecedor só pode mexer em: status (menos Cancelado/Sem resposta), responsavel, inicio_em, prazo, entregue_em.
create or replace function public.sol_salvar(p_token text, p_id bigint, p_dados jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  q jsonb := public._sol_exige(p_token);
  forn boolean := q->>'tipo' = 'fornecedor';
  quem text := (q->>'nome') || case when forn then ' (' || (q->>'fornecedor') || ')' else '' end;
  antes sol_cartoes; c sol_cartoes; d jsonb := coalesce(p_dados, '{}'::jsonb);
  permitidos text[] := case when forn then array['status','responsavel','inicio_em','prazo','entregue_em','observacoes']
    else array['fornecedor','assunto','descricao','link','responsavel','status','enviado_em','inicio_em','prazo',
               'entregue_em','ultimo_contato','emails','ordem','observacoes'] end;
  k text; diff jsonb := '{}'::jsonb; hoje date := public._sol_hoje();
begin
  if not (q->>'edita')::boolean then raise exception 'Seu acesso é só para ver.'; end if;
  for k in select jsonb_object_keys(d) loop
    if not k = any(permitidos) then raise exception 'Campo não permitido: %', k; end if;
  end loop;
  if forn and d ? 'status' and d->>'status' in ('Cancelado', 'Sem resposta') then
    raise exception 'Esse status é só para quem pediu.';
  end if;
  if d ? 'emails' and jsonb_typeof(d->'emails') = 'string' then
    d := jsonb_set(d, '{emails}', to_jsonb(regexp_split_to_array(trim(d->>'emails'), '[,;[:space:]]+')));
  end if;
  if d ? 'emails' then
    d := jsonb_set(d, '{emails}', coalesce((select jsonb_agg(distinct lower(e)) from jsonb_array_elements_text(d->'emails') e
      where e like '%_@_%._%'), '[]'::jsonb));
  end if;

  if p_id is null then
    if forn then raise exception 'Fornecedor não cria cartões.'; end if;
    if coalesce(trim(d->>'fornecedor'), '') = '' or coalesce(trim(d->>'assunto'), '') = '' then
      raise exception 'Preencha fornecedor e assunto.';
    end if;
    insert into sol_cartoes (fornecedor, assunto, criado_por, ordem)
      values (trim(d->>'fornecedor'), trim(d->>'assunto'), quem, extract(epoch from now()))
      returning * into antes;
    insert into sol_historico (cartao_id, quem, tipo, texto) values (antes.id, quem, 'criou', 'Criou o cartão');
    d := d - 'fornecedor' - 'assunto';
  else
    select * into antes from sol_cartoes where id = p_id for update;
    if antes.id is null or (forn and lower(antes.fornecedor) <> lower(q->>'fornecedor')) then
      raise exception 'Cartão não encontrado.';
    end if;
  end if;

  -- regras automáticas ao mudar o status
  if d ? 'status' and d->>'status' is distinct from antes.status then
    if d->>'status' in ('Em andamento', 'Entregue') and antes.inicio_em is null and not d ? 'inicio_em' then
      d := d || jsonb_build_object('inicio_em', hoje);
    end if;
    if d->>'status' = 'Entregue' and antes.entregue_em is null and not d ? 'entregue_em' then
      d := d || jsonb_build_object('entregue_em', hoje);
    end if;
  end if;
  if forn then d := d || jsonb_build_object('ultimo_contato', hoje); end if;   -- fornecedor mexeu = contato

  c := jsonb_populate_record(antes, (to_jsonb(antes) || d));
  if c.prazo is not null and antes.prazo_original is null then c.prazo_original := c.prazo; end if;

  for k in select unnest(permitidos || array['inicio_em','entregue_em','ultimo_contato']) loop
    if (to_jsonb(antes)->k) is distinct from (to_jsonb(c)->k) and not diff ? k then
      diff := diff || jsonb_build_object(k, jsonb_build_array(to_jsonb(antes)->k, to_jsonb(c)->k));
    end if;
  end loop;
  diff := diff - 'ordem';

  update sol_cartoes set
    fornecedor = c.fornecedor, assunto = c.assunto, descricao = c.descricao, link = c.link,
    responsavel = c.responsavel, status = c.status, enviado_em = c.enviado_em, inicio_em = c.inicio_em,
    prazo = c.prazo, prazo_original = c.prazo_original, entregue_em = c.entregue_em,
    ultimo_contato = c.ultimo_contato, emails = c.emails, ordem = c.ordem, observacoes = c.observacoes, atualizado_em = now(),
    ultimo_aviso = case when c.prazo is distinct from antes.prazo then null else ultimo_aviso end
  where id = antes.id returning * into c;

  if diff ? 'status' then
    insert into sol_historico (cartao_id, quem, tipo, texto, dados)
      values (c.id, quem, 'status', antes.status || ' → ' || c.status, diff);
  elsif p_id is not null and (diff - 'ultimo_contato') <> '{}'::jsonb then
    insert into sol_historico (cartao_id, quem, tipo, texto, dados)
      values (c.id, quem, 'editou', 'Alterou ' || (select string_agg(x, ', ') from jsonb_object_keys(diff - 'ultimo_contato') x), diff);
  end if;
  return public._sol_json(c, not forn)::json;
end $$;

create or replace function public.sol_comentar(p_token text, p_id bigint, p_texto text) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); c sol_cartoes; forn boolean := q->>'tipo' = 'fornecedor';
begin
  if coalesce(trim(p_texto), '') = '' then raise exception 'Escreva o comentário.'; end if;
  select * into c from sol_cartoes where id = p_id;
  if c.id is null or (forn and lower(c.fornecedor) <> lower(q->>'fornecedor')) then
    raise exception 'Cartão não encontrado.';
  end if;
  insert into sol_historico (cartao_id, quem, tipo, texto)
    values (p_id, (q->>'nome') || case when forn then ' (' || (q->>'fornecedor') || ')' else '' end,
            'comentario', left(trim(p_texto), 4000));
  update sol_cartoes set ultimo_contato = public._sol_hoje(), atualizado_em = now() where id = p_id;
  return 'ok';
end $$;

create or replace function public.sol_remover(p_token text, p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token, true);
begin
  delete from sol_cartoes where id = p_id;
  perform public._central_log(null, q->>'nome', 'editou', 'solicitacoes', 'Apagou o cartão ' || p_id);
  return 'ok';
end $$;

-- ---------------------------------------------------------------- acessos de fornecedor (administrador)
create or replace function public.sol_pessoas_lista(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token, true);
begin
  return coalesce((select json_agg(json_build_object('id', id, 'nome', nome, 'fornecedor', fornecedor,
    'email', email, 'ativo', ativo, 'ultimo_acesso', ultimo_acesso) order by fornecedor, nome) from sol_pessoas), '[]'::json);
end $$;

create or replace function public.sol_pessoa_salvar(p_token text, p_id bigint, p_nome text, p_fornecedor text,
  p_email text, p_senha text, p_ativo boolean) returns bigint
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token, true); novo bigint; h text;
begin
  if coalesce(trim(p_nome), '') = '' or coalesce(trim(p_fornecedor), '') = '' then
    raise exception 'Preencha nome e fornecedor.';
  end if;
  if p_senha is not null and trim(p_senha) <> '' then
    if length(trim(p_senha)) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
    if exists (select 1 from central_acessos where senha_hash = public._central_hash(trim(p_senha))) then
      raise exception 'Essa senha já é usada por alguém da Central. Escolha outra.';
    end if;
    h := public._central_hash('sol:' || trim(p_senha));
    if exists (select 1 from sol_pessoas where senha_hash = h and id is distinct from p_id) then
      raise exception 'Essa senha já é usada por outra pessoa. Escolha outra.';
    end if;
  end if;
  if p_id is null then
    if h is null then raise exception 'Defina a senha.'; end if;
    insert into sol_pessoas (nome, fornecedor, email, senha_hash, ativo)
      values (trim(p_nome), trim(p_fornecedor), nullif(trim(p_email), ''), h, coalesce(p_ativo, true)) returning id into novo;
  else
    update sol_pessoas set nome = trim(p_nome), fornecedor = trim(p_fornecedor), email = nullif(trim(p_email), ''),
      ativo = coalesce(p_ativo, true), senha_hash = coalesce(h, senha_hash) where id = p_id returning id into novo;
    if h is not null or not coalesce(p_ativo, true) then delete from sol_sessoes where pessoa_id = p_id; end if;
  end if;
  perform public._central_log(null, q->>'nome', 'cadastro', 'solicitacoes', 'Acesso de fornecedor: ' || trim(p_nome));
  return novo;
end $$;

create or replace function public.sol_pessoa_remover(p_token text, p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token, true);
begin
  delete from sol_pessoas where id = p_id;
  return 'ok';
end $$;

create or replace function public.sol_config_ver(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token, true);
begin
  return (select json_build_object('chave_robo', chave_robo, 'dias_sem_resposta', dias_sem_resposta,
    'link_quadro', link_quadro) from sol_config where id = 1);
end $$;

create or replace function public.sol_config_salvar(p_token text, p_dias int, p_nova_chave boolean default false) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare q jsonb := public._sol_exige(p_token, true);
begin
  update sol_config set dias_sem_resposta = greatest(1, coalesce(p_dias, dias_sem_resposta)),
    chave_robo = case when p_nova_chave then encode(gen_random_bytes(18), 'hex') else chave_robo end where id = 1;
  return public.sol_config_ver(p_token);
end $$;

-- ---------------------------------------------------------------- robô do e-mail (Apps Script)
-- Devolve os cartões que precisam de aviso HOJE (vencido, vence hoje/amanhã, sem resposta)
-- e que ainda não foram avisados hoje.
create or replace function public.sol_avisos(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if p_chave is null or p_chave <> (select chave_robo from sol_config where id = 1) then
    raise exception 'chave inválida' using errcode = '28000';
  end if;
  return coalesce((select json_agg(public._sol_json(c, true) || jsonb_build_object('link_quadro',
      (select link_quadro from sol_config where id = 1) || '?v=' || c.chave_publica))
    from sol_cartoes c
    where public._sol_situacao(c) in ('vencido', 'vence_hoje', 'vence_amanha', 'sem_resposta')
      and c.ultimo_aviso is distinct from public._sol_hoje()), '[]'::json);
end $$;

create or replace function public.sol_aviso_marcar(p_chave text, p_id bigint, p_motivo text, p_para text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if p_chave is null or p_chave <> (select chave_robo from sol_config where id = 1) then
    raise exception 'chave inválida' using errcode = '28000';
  end if;
  update sol_cartoes set ultimo_aviso = public._sol_hoje(), ultimo_motivo = p_motivo where id = p_id;
  insert into sol_historico (cartao_id, quem, tipo, texto)
    values (p_id, 'Aviso automático', 'aviso', 'E-mail enviado: ' || coalesce(p_motivo, '') || ' → ' || coalesce(p_para, ''));
  return 'ok';
end $$;

grant execute on function public.sol_entrar(text), public.sol_sessao(text), public.sol_sair(text),
  public.sol_listar(text), public.sol_cartao(text, bigint), public.sol_salvar(text, bigint, jsonb),
  public.sol_comentar(text, bigint, text), public.sol_remover(text, bigint),
  public.sol_pessoas_lista(text), public.sol_pessoa_salvar(text, bigint, text, text, text, text, boolean),
  public.sol_pessoa_remover(text, bigint), public.sol_config_ver(text), public.sol_config_salvar(text, int, boolean),
  public.sol_avisos(text), public.sol_aviso_marcar(text, bigint, text, text)
  to anon, authenticated;

-- ================================================================ E-MAIL PELO QUADRO + CONTATOS + LINK PÚBLICO
-- O quadro grava o e-mail (com anexos) numa fila; o Apps Script do Mizael (solicitacoes-aviso.gs)
-- busca a fila a cada minuto e envia pelo Gmail dele. No fim do corpo vai o link "veja a gestão".
create table if not exists public.sol_contatos (
  id          bigserial primary key,
  nome        text,
  email       text not null unique,
  fornecedor  text,
  usos        int not null default 0,
  ultimo_uso  timestamptz,
  criado_em   timestamptz not null default now()
);

create table if not exists public.sol_emails (
  id          bigserial primary key,
  cartao_id   bigint not null references public.sol_cartoes(id) on delete cascade,
  para        text[] not null,
  cc          text[] not null default '{}',
  assunto     text not null,
  corpo       text not null,
  status      text not null default 'pendente' check (status in ('pendente','enviando','enviado','erro')),
  erro        text,
  tentativas  int not null default 0,
  criado_por  text,
  criado_em   timestamptz not null default now(),
  enviado_em  timestamptz
);
create index if not exists sol_emails_fila on public.sol_emails (status, criado_em);

create table if not exists public.sol_anexos (
  id        bigserial primary key,
  email_id  bigint not null references public.sol_emails(id) on delete cascade,
  nome      text not null,
  tipo      text,
  tamanho   int not null,
  dados     bytea not null
);

alter table public.sol_contatos enable row level security;
alter table public.sol_emails   enable row level security;
alter table public.sol_anexos   enable row level security;
revoke all on public.sol_contatos, public.sol_emails, public.sol_anexos from anon, authenticated;

create or replace function public._sol_emails_limpos(p text[]) returns text[]
language sql immutable as $$
  select coalesce(array_agg(distinct lower(trim(e))), '{}') from unnest(coalesce(p, '{}')) e
  where trim(e) ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
$$;

-- ---------- contatos (só interno)
create or replace function public.sol_contatos_lista(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token);
begin
  if q->>'tipo' <> 'interno' then raise exception 'Só para quem pediu.'; end if;
  return coalesce((select json_agg(json_build_object('id', id, 'nome', nome, 'email', email, 'fornecedor', fornecedor, 'usos', usos)
    order by usos desc, nome nulls last, email) from sol_contatos), '[]'::json);
end $$;

create or replace function public.sol_contato_salvar(p_token text, p_id bigint, p_nome text, p_email text, p_fornecedor text) returns bigint
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); e text := lower(trim(p_email)); novo bigint;
begin
  if q->>'tipo' <> 'interno' or not (q->>'edita')::boolean then raise exception 'Sem permissão.'; end if;
  if e !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;
  if p_id is null then
    insert into sol_contatos (nome, email, fornecedor) values (nullif(trim(p_nome), ''), e, nullif(trim(p_fornecedor), ''))
    on conflict (email) do update set nome = coalesce(excluded.nome, sol_contatos.nome),
      fornecedor = coalesce(excluded.fornecedor, sol_contatos.fornecedor) returning id into novo;
  else
    update sol_contatos set nome = nullif(trim(p_nome), ''), email = e, fornecedor = nullif(trim(p_fornecedor), '')
    where id = p_id returning id into novo;
  end if;
  return novo;
end $$;

create or replace function public.sol_contato_remover(p_token text, p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token);
begin
  if q->>'tipo' <> 'interno' or not (q->>'edita')::boolean then raise exception 'Sem permissão.'; end if;
  delete from sol_contatos where id = p_id;
  return 'ok';
end $$;

-- ---------- escrever e-mail (vai para a fila)
-- p_anexos = [{"nome":"x.pdf","tipo":"application/pdf","base64":"..."}]  (até 15 MB no total)
create or replace function public.sol_email_enviar(p_token text, p_cartao bigint, p_para text[], p_cc text[],
  p_assunto text, p_corpo text, p_anexos jsonb default '[]'::jsonb) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare
  q jsonb := public._sol_exige(p_token); quem text := q->>'nome';
  para text[] := public._sol_emails_limpos(p_para); cc text[] := public._sol_emails_limpos(p_cc);
  c sol_cartoes; eid bigint; a jsonb; b bytea; total int := 0; nomes text[] := '{}'; x text;
begin
  if q->>'tipo' <> 'interno' or not (q->>'edita')::boolean then raise exception 'Só quem pediu envia e-mail pelo quadro.'; end if;
  select * into c from sol_cartoes where id = p_cartao for update;
  if c.id is null then raise exception 'Cartão não encontrado.'; end if;
  if cardinality(para) = 0 then raise exception 'Coloque pelo menos um e-mail válido em Para.'; end if;
  if coalesce(trim(p_assunto), '') = '' or coalesce(trim(p_corpo), '') = '' then raise exception 'Preencha assunto e texto do e-mail.'; end if;
  insert into sol_emails (cartao_id, para, cc, assunto, corpo, criado_por)
    values (c.id, para, cc, trim(p_assunto), p_corpo, quem) returning id into eid;
  for a in select * from jsonb_array_elements(coalesce(p_anexos, '[]'::jsonb)) loop
    b := decode(a->>'base64', 'base64');
    total := total + length(b);
    if total > 15 * 1024 * 1024 then raise exception 'Anexos passam de 15 MB. Mande um link em vez do arquivo.'; end if;
    insert into sol_anexos (email_id, nome, tipo, tamanho, dados)
      values (eid, coalesce(nullif(a->>'nome', ''), 'anexo'), nullif(a->>'tipo', ''), length(b), b);
    nomes := nomes || (a->>'nome');
  end loop;
  -- quem recebeu passa a receber os avisos de prazo; contatos ficam salvos
  update sol_cartoes set emails = public._sol_emails_limpos(emails || para || cc),
    enviado_em = case when not exists (select 1 from sol_emails where cartao_id = c.id and id <> eid) then public._sol_hoje() else enviado_em end,
    atualizado_em = now() where id = c.id;
  foreach x in array para || cc loop
    insert into sol_contatos (email, fornecedor, usos, ultimo_uso) values (x, c.fornecedor, 1, now())
    on conflict (email) do update set usos = sol_contatos.usos + 1, ultimo_uso = now();
  end loop;
  insert into sol_historico (cartao_id, quem, tipo, texto, dados) values (c.id, quem, 'email',
    'E-mail: ' || trim(p_assunto), jsonb_build_object('email_id', eid, 'anexos', to_jsonb(nomes), 'qtd_para', cardinality(para) + cardinality(cc)));
  return eid;
end $$;

-- e-mails do cartão (sem os arquivos)
create or replace function public.sol_emails_cartao(p_token text, p_cartao bigint) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); c sol_cartoes; v_int boolean := q->>'tipo' = 'interno';
begin
  select * into c from sol_cartoes where id = p_cartao;
  if c.id is null or (not v_int and lower(c.fornecedor) <> lower(q->>'fornecedor')) then raise exception 'Cartão não encontrado.'; end if;
  return coalesce((select json_agg(json_build_object('id', e.id, 'assunto', e.assunto, 'corpo', e.corpo,
      'para', case when v_int then e.para end, 'cc', case when v_int then e.cc end,
      'status', e.status, 'erro', e.erro, 'criado_por', e.criado_por, 'criado_em', e.criado_em, 'enviado_em', e.enviado_em,
      'anexos', (select coalesce(json_agg(json_build_object('id', an.id, 'nome', an.nome, 'tamanho', an.tamanho) order by an.id), '[]'::json)
                 from sol_anexos an where an.email_id = e.id)) order by e.criado_em desc)
    from sol_emails e where e.cartao_id = c.id), '[]'::json);
end $$;

create or replace function public.sol_anexo(p_token text, p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); r record;
begin
  select an.nome, an.tipo, encode(an.dados, 'base64') as base64, c.fornecedor into r
    from sol_anexos an join sol_emails e on e.id = an.email_id join sol_cartoes c on c.id = e.cartao_id where an.id = p_id;
  if r.nome is null or (q->>'tipo' = 'fornecedor' and lower(r.fornecedor) <> lower(q->>'fornecedor')) then
    raise exception 'Anexo não encontrado.';
  end if;
  return json_build_object('nome', r.nome, 'tipo', r.tipo, 'base64', replace(r.base64, E'\n', ''));
end $$;

-- ---------- link público (só ver): solicitacoes.html?v=<chave_publica>
create or replace function public.sol_publico(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
declare c sol_cartoes;
begin
  select * into c from sol_cartoes where chave_publica = p_chave and length(coalesce(p_chave, '')) >= 16;
  if c.id is null then return json_build_object('erro', 'Link inválido ou cartão apagado.'); end if;
  return json_build_object(
    'cartao', public._sol_json(c, false) - 'criado_por' - 'chave_publica',
    'historico', coalesce((select json_agg(json_build_object('ts', ts, 'quem', quem, 'tipo', tipo, 'texto', texto,
        'dados', case when tipo = 'email' then dados - 'email_id' else dados - 'emails' end) order by ts desc)
      from sol_historico where cartao_id = c.id and not (tipo = 'editou' and dados ?& array['emails'] and (dados - 'emails') = '{}'::jsonb)), '[]'::json),
    'emails', coalesce((select json_agg(json_build_object('assunto', e.assunto, 'corpo', e.corpo, 'criado_em', e.criado_em,
        'status', e.status, 'anexos', (select coalesce(json_agg(an.nome order by an.id), '[]'::json) from sol_anexos an where an.email_id = e.id))
        order by e.criado_em desc) from sol_emails e where e.cartao_id = c.id and not e.interno), '[]'::json));
end $$;

-- ---------- robô: fila de envio
create or replace function public.sol_emails_pendentes(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
declare e sol_emails;
begin
  if p_chave is null or p_chave <> (select chave_robo from sol_config where id = 1) then
    raise exception 'chave inválida' using errcode = '28000';
  end if;
  -- 'enviando' parado há mais de 15 min volta para a fila
  update sol_emails set status = 'pendente' where status = 'enviando' and criado_em < now() - interval '15 minutes' and tentativas < 3;
  select * into e from sol_emails where status = 'pendente' order by criado_em limit 1 for update skip locked;
  if e.id is null then return null; end if;
  update sol_emails set status = 'enviando', tentativas = tentativas + 1 where id = e.id;
  return json_build_object('id', e.id, 'para', e.para, 'cc', e.cc, 'assunto', e.assunto, 'corpo', e.corpo,
    'link', (select link_quadro from sol_config where id = 1) || '?v=' || (select chave_publica from sol_cartoes where id = e.cartao_id),
    'anexos', (select coalesce(json_agg(json_build_object('nome', nome, 'tipo', tipo, 'base64', replace(encode(dados, 'base64'), E'\n', '')) order by id), '[]'::json)
               from sol_anexos where email_id = e.id));
end $$;

create or replace function public.sol_email_marcar(p_chave text, p_id bigint, p_ok boolean, p_erro text default null) returns text
language plpgsql security definer set search_path = public as $$
declare e sol_emails;
begin
  if p_chave is null or p_chave <> (select chave_robo from sol_config where id = 1) then
    raise exception 'chave inválida' using errcode = '28000';
  end if;
  update sol_emails set status = case when p_ok then 'enviado' when tentativas >= 3 then 'erro' else 'pendente' end,
    erro = case when p_ok then null else left(p_erro, 500) end, enviado_em = case when p_ok then now() end
  where id = p_id returning * into e;
  if p_ok then
    insert into sol_historico (cartao_id, quem, tipo, texto) values (e.cartao_id, 'Envio automático', 'aviso',
      'E-mail "' || e.assunto || '" enviado');
  elsif e.status = 'erro' then
    insert into sol_historico (cartao_id, quem, tipo, texto) values (e.cartao_id, 'Envio automático', 'aviso',
      'Falhou o envio do e-mail "' || e.assunto || '": ' || coalesce(left(p_erro, 200), ''));
  end if;
  return e.status;
end $$;

grant execute on function public.sol_contatos_lista(text), public.sol_contato_salvar(text, bigint, text, text, text),
  public.sol_contato_remover(text, bigint), public.sol_email_enviar(text, bigint, text[], text[], text, text, jsonb),
  public.sol_emails_cartao(text, bigint), public.sol_anexo(text, bigint), public.sol_publico(text),
  public.sol_emails_pendentes(text), public.sol_email_marcar(text, bigint, boolean, text)
  to anon, authenticated;

-- ================================================================ REPASSAR PARA ALGUÉM DE FORA (com aprovação)
-- O fornecedor pede acesso para outra pessoa → aparece para o administrador (quadro + e-mail do robô)
-- → ao aprovar, cria a senha da pessoa (mesmo fornecedor) e manda por e-mail.
alter table public.sol_emails add column if not exists segredo text;           -- senha que o robô troca por {{SENHA}}; apagada ao enviar
alter table public.sol_emails add column if not exists interno boolean not null default false;  -- não aparece no link público

create table if not exists public.sol_pedidos_acesso (
  id            bigserial primary key,
  cartao_id     bigint references public.sol_cartoes(id) on delete cascade,
  fornecedor    text not null,
  nome          text not null,
  email         text not null,
  mensagem      text,
  pedido_por    text,
  status        text not null default 'pendente' check (status in ('pendente','aprovado','recusado')),
  avisado_em    timestamptz,                 -- robô já mandou o e-mail para o administrador
  decidido_por  text,
  decidido_em   timestamptz,
  criado_em     timestamptz not null default now()
);
alter table public.sol_pedidos_acesso enable row level security;
revoke all on public.sol_pedidos_acesso from anon, authenticated;

create or replace function public.sol_repassar(p_token text, p_cartao bigint, p_nome text, p_email text, p_mensagem text) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); c sol_cartoes; e text := lower(trim(p_email));
  quem text := (q->>'nome') || case when q->>'tipo' = 'fornecedor' then ' (' || (q->>'fornecedor') || ')' else '' end;
begin
  if not (q->>'edita')::boolean then raise exception 'Seu acesso é só para ver.'; end if;
  select * into c from sol_cartoes where id = p_cartao for update;
  if c.id is null or (q->>'tipo' = 'fornecedor' and lower(c.fornecedor) <> lower(q->>'fornecedor')) then raise exception 'Cartão não encontrado.'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'Coloque o nome da pessoa.'; end if;
  if e !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;
  update sol_cartoes set responsavel = trim(p_nome), atualizado_em = now(),
    ultimo_contato = case when q->>'tipo' = 'fornecedor' then public._sol_hoje() else ultimo_contato end where id = c.id;
  insert into sol_historico (cartao_id, quem, tipo, texto, dados) values (c.id, quem, 'status',
    'Repassou para ' || trim(p_nome) || coalesce(': ' || nullif(trim(p_mensagem), ''), ''),
    jsonb_build_object('responsavel', jsonb_build_array(c.responsavel, trim(p_nome))));
  if exists (select 1 from sol_pessoas where lower(email) = e and lower(fornecedor) in (lower(c.fornecedor), '*') and ativo) then
    update sol_cartoes set emails = public._sol_emails_limpos(emails || e) where id = c.id;
    return 'ja_tem_acesso';
  end if;
  if not exists (select 1 from sol_pedidos_acesso where lower(email) = e and status = 'pendente' and lower(fornecedor) = lower(c.fornecedor)) then
    insert into sol_pedidos_acesso (cartao_id, fornecedor, nome, email, mensagem, pedido_por)
      values (c.id, c.fornecedor, trim(p_nome), e, nullif(trim(p_mensagem), ''), quem);
  end if;
  insert into sol_historico (cartao_id, quem, tipo, texto) values (c.id, 'Quadro', 'aviso',
    'Pedido de acesso para ' || trim(p_nome) || ' aguardando aprovação');
  return 'pedido';
end $$;

create or replace function public.sol_pedidos_lista(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token);
begin
  if q->>'tipo' <> 'interno' then return '[]'::json; end if;
  return coalesce((select json_agg(json_build_object('id', p.id, 'cartao_id', p.cartao_id, 'assunto', c.assunto, 'fornecedor', p.fornecedor,
      'nome', p.nome, 'email', p.email, 'mensagem', p.mensagem, 'pedido_por', p.pedido_por, 'criado_em', p.criado_em) order by p.criado_em)
    from sol_pedidos_acesso p left join sol_cartoes c on c.id = p.cartao_id where p.status = 'pendente'), '[]'::json);
end $$;

create or replace function public.sol_pedido_decidir(p_token text, p_id bigint, p_aprovar boolean) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare q jsonb := public._sol_exige(p_token, true); p sol_pedidos_acesso; senha text; h text; pid bigint; eid bigint; c sol_cartoes; i int := 0;
begin
  select * into p from sol_pedidos_acesso where id = p_id and status = 'pendente' for update;
  if p.id is null then raise exception 'Pedido não encontrado ou já decidido.'; end if;
  update sol_pedidos_acesso set status = case when p_aprovar then 'aprovado' else 'recusado' end,
    decidido_por = q->>'nome', decidido_em = now() where id = p.id;
  if not p_aprovar then
    if p.cartao_id is not null then
      insert into sol_historico (cartao_id, quem, tipo, texto) values (p.cartao_id, q->>'nome', 'aviso', 'Recusou o acesso de ' || p.nome);
    end if;
    return json_build_object('status', 'recusado');
  end if;
  -- senha de 4 números (entra com e-mail + senha)
  senha := lpad(((get_byte(gen_random_bytes(1), 0) * 256 + get_byte(gen_random_bytes(1), 0)) % 10000)::text, 4, '0');
  h := public._central_hash('sol:' || p.email || ':' || senha);
  select id into pid from sol_pessoas where lower(email) = p.email and lower(fornecedor) = lower(p.fornecedor);
  if pid is null then
    insert into sol_pessoas (nome, fornecedor, email, senha_hash) values (p.nome, p.fornecedor, p.email, h) returning id into pid;
  else
    update sol_pessoas set senha_hash = h, ativo = true, nome = p.nome where id = pid;
    delete from sol_sessoes where pessoa_id = pid;
  end if;
  insert into sol_contatos (nome, email, fornecedor) values (p.nome, p.email, p.fornecedor)
    on conflict (email) do update set nome = coalesce(sol_contatos.nome, excluded.nome);
  select * into c from sol_cartoes where id = p.cartao_id;
  if c.id is not null then
    update sol_cartoes set emails = public._sol_emails_limpos(emails || p.email) where id = c.id;
    insert into sol_emails (cartao_id, para, assunto, corpo, criado_por, segredo, interno)
      values (c.id, array[p.email], 'Acesso ao quadro de solicitações – ' || c.assunto,
        'Olá, ' || p.nome || '.' || E'\n\n' ||
        coalesce(p.pedido_por, 'Um colega') || ' repassou para você a demanda "' || c.assunto || '".' || E'\n\n' ||
        'Para atualizar o andamento (status, datas, prazo e recados), abra o link abaixo, clique em "Entrar para atualizar" e use:' || E'\n\n' ||
        '    E-mail: ' || p.email || E'\n' || '    Senha: {{SENHA}}' || E'\n\n' ||
        'Se quiser, peça ao Mizael para trocar a senha pelos 4 últimos números do seu celular.' || E'\n\n' ||
        'A senha é pessoal: não compartilhe. Você vê só as demandas de ' || p.fornecedor || '.',
        q->>'nome', senha, true) returning id into eid;
    insert into sol_historico (cartao_id, quem, tipo, texto) values (c.id, q->>'nome', 'aviso',
      'Aprovou o acesso de ' || p.nome || ' (senha enviada por e-mail)');
  end if;
  perform public._central_log(null, q->>'nome', 'cadastro', 'solicitacoes', 'Aprovou acesso de fornecedor: ' || p.nome);
  return json_build_object('status', 'aprovado', 'senha', senha, 'email_enviado', eid is not null);
end $$;

-- robô: pedidos novos para avisar o administrador por e-mail
create or replace function public.sol_pedidos_avisar(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
declare r json;
begin
  if p_chave is null or p_chave <> (select chave_robo from sol_config where id = 1) then
    raise exception 'chave inválida' using errcode = '28000';
  end if;
  select coalesce(json_agg(json_build_object('nome', p.nome, 'email', p.email, 'fornecedor', p.fornecedor, 'pedido_por', p.pedido_por,
      'mensagem', p.mensagem, 'assunto', c.assunto)), '[]'::json) into r
    from sol_pedidos_acesso p left join sol_cartoes c on c.id = p.cartao_id where p.status = 'pendente' and p.avisado_em is null;
  update sol_pedidos_acesso set avisado_em = now() where status = 'pendente' and avisado_em is null;
  return json_build_object('pedidos', r, 'link', (select link_quadro from sol_config where id = 1) || '?acessos=1');
end $$;

-- o robô busca a fila com a senha (segredo) e, ao marcar enviado, ela é apagada
create or replace function public.sol_emails_pendentes(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
declare e sol_emails;
begin
  if p_chave is null or p_chave <> (select chave_robo from sol_config where id = 1) then
    raise exception 'chave inválida' using errcode = '28000';
  end if;
  update sol_emails set status = 'pendente' where status = 'enviando' and criado_em < now() - interval '15 minutes' and tentativas < 3;
  select * into e from sol_emails where status = 'pendente' order by criado_em limit 1 for update skip locked;
  if e.id is null then return null; end if;
  update sol_emails set status = 'enviando', tentativas = tentativas + 1 where id = e.id;
  return json_build_object('id', e.id, 'para', e.para, 'cc', e.cc, 'assunto', e.assunto,
    'corpo', replace(e.corpo, '{{SENHA}}', coalesce(e.segredo, '')),
    'link', (select link_quadro from sol_config where id = 1) || '?v=' || (select chave_publica from sol_cartoes where id = e.cartao_id),
    'anexos', (select coalesce(json_agg(json_build_object('nome', nome, 'tipo', tipo, 'base64', replace(encode(dados, 'base64'), E'\n', ''))
      order by id), '[]'::json) from sol_anexos where email_id = e.id));
end $$;
create or replace function public._sol_apaga_segredo() returns trigger language plpgsql as $$
begin if new.status = 'enviado' then new.segredo := null; end if; return new; end $$;
drop trigger if exists sol_emails_segredo on public.sol_emails;
create trigger sol_emails_segredo before update on public.sol_emails for each row execute function public._sol_apaga_segredo();

grant execute on function public.sol_repassar(text, bigint, text, text, text), public.sol_pedidos_lista(text),
  public.sol_pedido_decidir(text, bigint, boolean), public.sol_pedidos_avisar(text) to anon, authenticated;

-- ================================================================ v4: DOCUMENTOS DO CARTÃO, LINK COM NOME DO PROCESSO, OBSERVAÇÕES
-- Documentos (PDF, Word, Excel…) ficam no cartão: dá para baixar pelo quadro e pelo link público,
-- e vão anexados nos e-mails. Link público: ?d=<nome-do-processo-xxxxxx>.
alter table public.sol_cartoes add column if not exists slug text unique;
alter table public.sol_cartoes add column if not exists observacoes text;        -- próximos passos (depois de assumido)
alter table public.sol_anexos add column if not exists cartao_id bigint references public.sol_cartoes(id) on delete cascade;
alter table public.sol_anexos add column if not exists enviado_por text;
alter table public.sol_anexos add column if not exists criado_em timestamptz not null default now();
alter table public.sol_anexos alter column email_id drop not null;
update public.sol_anexos a set cartao_id = e.cartao_id from public.sol_emails e where a.email_id = e.id and a.cartao_id is null;
create table if not exists public.sol_email_anexos (
  email_id bigint not null references public.sol_emails(id) on delete cascade,
  anexo_id bigint not null references public.sol_anexos(id) on delete cascade,
  primary key (email_id, anexo_id)
);
alter table public.sol_email_anexos enable row level security;
revoke all on public.sol_email_anexos from anon, authenticated;
insert into public.sol_email_anexos (email_id, anexo_id) select email_id, id from public.sol_anexos where email_id is not null
on conflict do nothing;

create or replace function public._sol_slug(p text) returns text
language sql volatile set search_path = public, extensions as $$
  -- até 4 palavras do assunto (sem acento, sem palavras curtas tipo "de", "da") + 6 letras aleatórias
  select coalesce(nullif((select string_agg(w, '-') from (select w from regexp_split_to_table(
      regexp_replace(lower(translate(coalesce(p, ''),
        'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ', 'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')), '[^a-z0-9]+', ' ', 'g'),
      '\s+') with ordinality t(w, n) where length(w) > 2 and w not in ('para','com','que','dos','das','nos','nas','uma','por') order by n limit 4) x), ''), 'demanda')
    || '-' || (select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + (get_byte(gen_random_bytes(1), 0) % 31), 1), '')
               from generate_series(1, 6))
$$;
create or replace function public._sol_slug_trg() returns trigger language plpgsql as $$
begin
  if new.slug is null then new.slug := public._sol_slug(new.assunto); end if;
  return new;
end $$;
drop trigger if exists sol_cartoes_slug on public.sol_cartoes;
create trigger sol_cartoes_slug before insert on public.sol_cartoes for each row execute function public._sol_slug_trg();
update public.sol_cartoes set slug = public._sol_slug(assunto) where slug is null;
-- endereço novo (organização Gestão Integrada no GitHub)
alter table public.sol_config alter column link_quadro set default 'https://gestao-integrada.github.io/demandas/';
update public.sol_config set link_quadro = 'https://gestao-integrada.github.io/demandas/'
 where id = 1 and link_quadro like '%zael20.github.io%';

create or replace function public._sol_link(c public.sol_cartoes) returns text
language sql stable as $$ select (select link_quadro from public.sol_config where id = 1) || '?d=' || coalesce(c.slug, c.chave_publica) $$;

create or replace function public._sol_por_chave(p_chave text) returns public.sol_cartoes
language sql stable security definer set search_path = public as $$
  select * from sol_cartoes where length(coalesce(p_chave, '')) >= 10 and (slug = p_chave or chave_publica = p_chave) limit 1
$$;

create or replace function public._sol_docs(p_cartao bigint) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', id, 'nome', nome, 'tipo', tipo, 'tamanho', tamanho,
    'enviado_por', enviado_por, 'criado_em', criado_em) order by id), '[]'::json) from sol_anexos where cartao_id = p_cartao
$$;

-- enviar um documento para o cartão (interno ou o fornecedor do cartão)
create or replace function public.sol_doc_enviar(p_token text, p_cartao bigint, p_nome text, p_tipo text, p_base64 text) returns bigint
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); c sol_cartoes; b bytea; novo bigint;
  quem text := (q->>'nome') || case when q->>'tipo' = 'fornecedor' then ' (' || (q->>'fornecedor') || ')' else '' end;
begin
  if not (q->>'edita')::boolean then raise exception 'Seu acesso é só para ver.'; end if;
  select * into c from sol_cartoes where id = p_cartao;
  if c.id is null or (q->>'tipo' = 'fornecedor' and lower(c.fornecedor) <> lower(q->>'fornecedor')) then raise exception 'Cartão não encontrado.'; end if;
  b := decode(p_base64, 'base64');
  if length(b) > 15 * 1024 * 1024 then raise exception 'Arquivo passa de 15 MB.'; end if;
  insert into sol_anexos (cartao_id, nome, tipo, tamanho, dados, enviado_por)
    values (c.id, coalesce(nullif(trim(p_nome), ''), 'documento'), nullif(p_tipo, ''), length(b), b, quem) returning id into novo;
  insert into sol_historico (cartao_id, quem, tipo, texto) values (c.id, quem, 'editou', 'Anexou o documento ' || coalesce(p_nome, ''));
  update sol_cartoes set atualizado_em = now(),
    ultimo_contato = case when q->>'tipo' = 'fornecedor' then public._sol_hoje() else ultimo_contato end where id = c.id;
  return novo;
end $$;

create or replace function public.sol_doc_remover(p_token text, p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); a record;
begin
  if q->>'tipo' <> 'interno' or not (q->>'edita')::boolean then raise exception 'Sem permissão.'; end if;
  select id, cartao_id, nome into a from sol_anexos where id = p_id;
  if a.id is null then return 'ok'; end if;
  if exists (select 1 from sol_email_anexos where anexo_id = a.id) then
    update sol_anexos set cartao_id = null where id = a.id;     -- já foi por e-mail: some do cartão, mas fica no e-mail
  else
    delete from sol_anexos where id = a.id;
  end if;
  insert into sol_historico (cartao_id, quem, tipo, texto) values (a.cartao_id, q->>'nome', 'editou', 'Removeu o documento ' || a.nome);
  return 'ok';
end $$;

create or replace function public.sol_anexo(p_token text, p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); r record;
begin
  select an.nome, an.tipo, encode(an.dados, 'base64') as base64, c.fornecedor into r
    from sol_anexos an left join sol_emails e on e.id = an.email_id
    join sol_cartoes c on c.id = coalesce(an.cartao_id, e.cartao_id) where an.id = p_id;
  if r.nome is null or (q->>'tipo' = 'fornecedor' and lower(r.fornecedor) <> lower(q->>'fornecedor')) then
    raise exception 'Anexo não encontrado.';
  end if;
  return json_build_object('nome', r.nome, 'tipo', r.tipo, 'base64', replace(r.base64, E'\n', ''));
end $$;

-- baixar pelo link público (só documentos que estão no cartão)
create or replace function public.sol_anexo_publico(p_chave text, p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare c sol_cartoes := public._sol_por_chave(p_chave); r record;
begin
  if c.id is null then raise exception 'Link inválido.'; end if;
  select nome, tipo, encode(dados, 'base64') as b into r from sol_anexos where id = p_id and cartao_id = c.id;
  if r.nome is null then raise exception 'Documento não encontrado.'; end if;
  return json_build_object('nome', r.nome, 'tipo', r.tipo, 'base64', replace(r.b, E'\n', ''));
end $$;

create or replace function public.sol_cartao(p_token text, p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); c sol_cartoes;
begin
  select * into c from sol_cartoes where id = p_id;
  if c.id is null or (q->>'tipo' = 'fornecedor' and lower(c.fornecedor) <> lower(q->>'fornecedor')) then
    raise exception 'Cartão não encontrado.';
  end if;
  return json_build_object('cartao', public._sol_json(c, q->>'tipo' = 'interno'), 'link', public._sol_link(c), 'docs', public._sol_docs(c.id),
    'historico', coalesce((select json_agg(h order by h.ts desc) from
      (select ts, quem, tipo, texto, dados from sol_historico where cartao_id = p_id) h), '[]'::json));
end $$;

-- e-mail: p_docs = documentos do cartão escolhidos; p_anexos = arquivos novos (viram documentos do cartão)
drop function if exists public.sol_email_enviar(text, bigint, text[], text[], text, text, jsonb);
create or replace function public.sol_email_enviar(p_token text, p_cartao bigint, p_para text[], p_cc text[],
  p_assunto text, p_corpo text, p_anexos jsonb default '[]'::jsonb, p_docs bigint[] default '{}') returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare
  q jsonb := public._sol_exige(p_token); quem text := q->>'nome';
  para text[] := public._sol_emails_limpos(p_para); cc text[] := public._sol_emails_limpos(p_cc);
  c sol_cartoes; eid bigint; a jsonb; b bytea; aid bigint; total bigint; nomes text[]; x text; primeiro boolean;
begin
  if q->>'tipo' <> 'interno' or not (q->>'edita')::boolean then raise exception 'Só quem pediu envia e-mail pelo quadro.'; end if;
  select * into c from sol_cartoes where id = p_cartao for update;
  if c.id is null then raise exception 'Cartão não encontrado.'; end if;
  if cardinality(para) = 0 then raise exception 'Coloque pelo menos um e-mail válido em Para.'; end if;
  if coalesce(trim(p_assunto), '') = '' or coalesce(trim(p_corpo), '') = '' then raise exception 'Preencha assunto e texto do e-mail.'; end if;
  primeiro := not exists (select 1 from sol_emails where cartao_id = c.id and not interno);
  insert into sol_emails (cartao_id, para, cc, assunto, corpo, criado_por)
    values (c.id, para, cc, trim(p_assunto), p_corpo, quem) returning id into eid;
  for a in select * from jsonb_array_elements(coalesce(p_anexos, '[]'::jsonb)) loop
    b := decode(a->>'base64', 'base64');
    insert into sol_anexos (cartao_id, nome, tipo, tamanho, dados, enviado_por)
      values (c.id, coalesce(nullif(a->>'nome', ''), 'anexo'), nullif(a->>'tipo', ''), length(b), b, quem) returning id into aid;
    insert into sol_email_anexos values (eid, aid);
  end loop;
  insert into sol_email_anexos (email_id, anexo_id)
    select eid, id from sol_anexos where cartao_id = c.id and id = any(coalesce(p_docs, '{}')) on conflict do nothing;
  select coalesce(sum(an.tamanho), 0), coalesce(array_agg(an.nome order by an.id), '{}') into total, nomes
    from sol_email_anexos ea join sol_anexos an on an.id = ea.anexo_id where ea.email_id = eid;
  if total > 20 * 1024 * 1024 then raise exception 'Anexos passam de 20 MB (limite do Gmail é 25). Tire algum arquivo.'; end if;
  update sol_cartoes set emails = public._sol_emails_limpos(emails || para || cc),
    enviado_em = case when primeiro then public._sol_hoje() else enviado_em end,
    descricao = case when primeiro and coalesce(descricao, '') = '' then p_corpo else descricao end,
    atualizado_em = now() where id = c.id;
  foreach x in array para || cc loop
    insert into sol_contatos (email, fornecedor, usos, ultimo_uso) values (x, c.fornecedor, 1, now())
    on conflict (email) do update set usos = sol_contatos.usos + 1, ultimo_uso = now();
  end loop;
  insert into sol_historico (cartao_id, quem, tipo, texto, dados) values (c.id, quem, 'email',
    'E-mail: ' || trim(p_assunto), jsonb_build_object('email_id', eid, 'anexos', to_jsonb(nomes), 'qtd_para', cardinality(para) + cardinality(cc)));
  return eid;
end $$;

create or replace function public.sol_emails_cartao(p_token text, p_cartao bigint) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); c sol_cartoes; v_int boolean := q->>'tipo' = 'interno';
begin
  select * into c from sol_cartoes where id = p_cartao;
  if c.id is null or (not v_int and lower(c.fornecedor) <> lower(q->>'fornecedor')) then raise exception 'Cartão não encontrado.'; end if;
  return coalesce((select json_agg(json_build_object('id', e.id, 'assunto', e.assunto, 'corpo', e.corpo,
      'para', case when v_int then e.para end, 'cc', case when v_int then e.cc end,
      'status', e.status, 'erro', e.erro, 'criado_por', e.criado_por, 'criado_em', e.criado_em, 'enviado_em', e.enviado_em,
      'anexos', (select coalesce(json_agg(json_build_object('id', an.id, 'nome', an.nome, 'tamanho', an.tamanho) order by an.id), '[]'::json)
                 from sol_email_anexos ea join sol_anexos an on an.id = ea.anexo_id where ea.email_id = e.id)) order by e.criado_em desc)
    from sol_emails e where e.cartao_id = c.id), '[]'::json);
end $$;

create or replace function public.sol_publico(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
declare c sol_cartoes := public._sol_por_chave(p_chave);
begin
  if c.id is null then return json_build_object('erro', 'Link inválido ou demanda apagada.'); end if;
  return json_build_object(
    'cartao', public._sol_json(c, false) - 'criado_por' - 'chave_publica',
    'docs', public._sol_docs(c.id),
    'historico', coalesce((select json_agg(json_build_object('ts', ts, 'quem', quem, 'tipo', tipo, 'texto', texto,
        'dados', case when tipo = 'email' then dados - 'email_id' else dados - 'emails' end) order by ts desc)
      from sol_historico where cartao_id = c.id and not (tipo = 'editou' and dados ?& array['emails'] and (dados - 'emails') = '{}'::jsonb)), '[]'::json),
    'emails', coalesce((select json_agg(json_build_object('assunto', e.assunto, 'corpo', e.corpo, 'criado_em', e.criado_em, 'status', e.status,
        'anexos', (select coalesce(json_agg(an.nome order by an.id), '[]'::json) from sol_email_anexos ea join sol_anexos an on an.id = ea.anexo_id where ea.email_id = e.id))
        order by e.criado_em desc) from sol_emails e where e.cartao_id = c.id and not e.interno), '[]'::json));
end $$;

create or replace function public.sol_emails_pendentes(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
declare e sol_emails; c sol_cartoes;
begin
  if p_chave is null or p_chave <> (select chave_robo from sol_config where id = 1) then
    raise exception 'chave inválida' using errcode = '28000';
  end if;
  update sol_emails set status = 'pendente' where status = 'enviando' and criado_em < now() - interval '15 minutes' and tentativas < 3;
  select * into e from sol_emails where status = 'pendente' order by criado_em limit 1 for update skip locked;
  if e.id is null then return null; end if;
  update sol_emails set status = 'enviando', tentativas = tentativas + 1 where id = e.id;
  select * into c from sol_cartoes where id = e.cartao_id;
  return json_build_object('id', e.id, 'para', e.para, 'cc', e.cc, 'assunto', e.assunto,
    'corpo', replace(e.corpo, '{{SENHA}}', coalesce(e.segredo, '')), 'link', public._sol_link(c), 'processo', c.assunto,
    'anexos', (select coalesce(json_agg(json_build_object('nome', an.nome, 'tipo', an.tipo, 'base64', replace(encode(an.dados, 'base64'), E'\n', ''))
      order by an.id), '[]'::json) from sol_email_anexos ea join sol_anexos an on an.id = ea.anexo_id where ea.email_id = e.id));
end $$;

create or replace function public.sol_avisos(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if p_chave is null or p_chave <> (select chave_robo from sol_config where id = 1) then
    raise exception 'chave inválida' using errcode = '28000';
  end if;
  return coalesce((select json_agg(public._sol_json(c, true) || jsonb_build_object('link_quadro', public._sol_link(c)))
    from sol_cartoes c
    where public._sol_situacao(c) in ('vencido', 'vence_hoje', 'vence_amanha', 'sem_resposta')
      and c.ultimo_aviso is distinct from public._sol_hoje()), '[]'::json);
end $$;

grant execute on function public.sol_doc_enviar(text, bigint, text, text, text), public.sol_doc_remover(text, bigint),
  public.sol_anexo_publico(text, bigint), public.sol_email_enviar(text, bigint, text[], text[], text, text, jsonb, bigint[])
  to anon, authenticated;
revoke execute on function public._sol_por_chave(text), public._sol_docs(bigint) from public, anon, authenticated;

-- ================================================================ v5: FORNECEDOR ENTRA COM E-MAIL + SENHA (pode ser 4 números)
-- 4 números sozinhos seriam fáceis de chutar; com o e-mail junto e trava de 5 erros (15 min), fica seguro.
alter table public.sol_pessoas drop constraint if exists sol_pessoas_senha_hash_key;
alter table public.sol_pessoas add column if not exists falhas int not null default 0;
alter table public.sol_pessoas add column if not exists travado_ate timestamptz;
create unique index if not exists sol_pessoas_email on public.sol_pessoas (lower(email)) where email is not null;

drop function if exists public.sol_entrar(text);
create or replace function public.sol_entrar(p_senha text, p_email text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a central_acessos; p sol_pessoas; tk text; e text := lower(trim(coalesce(p_email, '')));
begin
  if (select count(*) from central_acessos_log where evento = 'senha_errada' and painel = 'solicitacoes'
      and ts > now() - interval '10 minutes') >= 30 then
    return json_build_object('erro', 'Muitas tentativas erradas. Espere 10 minutos.');
  end if;
  if e <> '' then
    -- fornecedor: e-mail + senha
    select * into p from sol_pessoas where lower(email) = e and ativo;
    if p.id is not null and p.travado_ate > now() then
      return json_build_object('erro', 'Muitas tentativas erradas neste e-mail. Espere 15 minutos.');
    end if;
    if p.id is not null and (p.senha_hash = public._central_hash('sol:' || e || ':' || trim(p_senha))
                             or p.senha_hash = public._central_hash('sol:' || trim(p_senha))) then
      update sol_pessoas set falhas = 0, travado_ate = null where id = p.id;
      tk := 'tfq_' || encode(gen_random_bytes(24), 'hex');
      insert into sol_sessoes (token, pessoa_id, expira_em) values (tk, p.id, now() + interval '60 days');
      delete from sol_sessoes where expira_em < now();
      perform public._central_log(null, p.nome || ' (' || p.fornecedor || ')', 'entrou', 'solicitacoes', 'Fornecedor entrou no quadro');
      return (jsonb_build_object('token', tk) || public._sol_quem(tk))::json;
    end if;
    if p.id is not null then
      update sol_pessoas set falhas = falhas + 1,
        travado_ate = case when falhas + 1 >= 5 then now() + interval '15 minutes' end where id = p.id;
    end if;
    perform public._central_log(null, e, 'senha_errada', 'solicitacoes');
    return json_build_object('erro', 'E-mail ou senha incorretos.');
  end if;
  -- da casa: senha pessoal da Central
  select * into a from central_acessos where senha_hash = public._central_hash(trim(p_senha)) and ativo;
  if a.id is not null then
    if not (a.admin or coalesce(a.perms, '{}'::jsonb) ? 'solicitacoes') then
      return json_build_object('erro', 'Sua senha não tem acesso ao quadro de solicitações.');
    end if;
    tk := 'tfs_' || encode(gen_random_bytes(24), 'hex');
    insert into central_sessoes (token, acesso_id, expira_em) values (tk, a.id, now() + interval '30 days');
    perform public._central_log(a.id, a.nome, 'entrou', 'solicitacoes', 'Entrou no quadro de solicitações');
    return (jsonb_build_object('token', tk) || public._sol_quem(tk))::json;
  end if;
  -- senha de gestores (a mesma da Lotação)
  if exists (select 1 from lotacao_admin where id = 1 and senha_hash = crypt(trim(p_senha), senha_hash)) then
    tk := 'tfg_' || encode(gen_random_bytes(24), 'hex');
    insert into sol_sessoes_gestor (token, expira_em) values (tk, now() + interval '30 days');
    delete from sol_sessoes_gestor where expira_em < now();
    perform public._central_log(null, 'Senha de gestores', 'entrou', 'solicitacoes', 'Entrou no quadro de solicitações');
    return (jsonb_build_object('token', tk) || public._sol_quem(tk))::json;
  end if;
  perform public._central_log(null, null, 'senha_errada', 'solicitacoes');
  return json_build_object('erro', case when trim(p_senha) = '8015'
    then 'O código geral 8015 não vale aqui. Use sua senha pessoal da Central ou a senha de gestores.'
    else 'Senha incorreta. Se você é de fornecedor, preencha também o seu e-mail.' end);
end $$;

create or replace function public.sol_pessoa_salvar(p_token text, p_id bigint, p_nome text, p_fornecedor text,
  p_email text, p_senha text, p_ativo boolean) returns bigint
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token, true); novo bigint; h text; e text := lower(trim(coalesce(p_email, '')));
begin
  if coalesce(trim(p_nome), '') = '' or coalesce(trim(p_fornecedor), '') = '' then
    raise exception 'Preencha nome e fornecedor.';
  end if;
  if e !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Preencha o e-mail da pessoa (ela entra com e-mail + senha).'; end if;
  if exists (select 1 from sol_pessoas where lower(email) = e and id is distinct from p_id) then
    raise exception 'Já existe um acesso com esse e-mail.';
  end if;
  if p_senha is not null and trim(p_senha) <> '' then
    if length(trim(p_senha)) < 4 then raise exception 'A senha precisa ter pelo menos 4 caracteres (ex.: 4 últimos números do celular).'; end if;
    h := public._central_hash('sol:' || e || ':' || trim(p_senha));
  end if;
  if p_id is null then
    if h is null then raise exception 'Defina a senha.'; end if;
    insert into sol_pessoas (nome, fornecedor, email, senha_hash, ativo)
      values (trim(p_nome), trim(p_fornecedor), e, h, coalesce(p_ativo, true)) returning id into novo;
  else
    update sol_pessoas set nome = trim(p_nome), fornecedor = trim(p_fornecedor), email = e,
      ativo = coalesce(p_ativo, true), falhas = 0, travado_ate = null,
      senha_hash = coalesce(h, senha_hash) where id = p_id returning id into novo;
    if h is not null or not coalesce(p_ativo, true) then delete from sol_sessoes where pessoa_id = p_id; end if;
  end if;
  perform public._central_log(null, q->>'nome', 'cadastro', 'solicitacoes', 'Acesso de fornecedor: ' || trim(p_nome));
  return novo;
end $$;

grant execute on function public.sol_entrar(text, text) to anon, authenticated;

-- contatos e acessos numa lista só (o administrador vê e cria o acesso de cada contato)
create or replace function public.sol_contatos_lista(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); adm boolean := (q->>'admin')::boolean;
begin
  if q->>'tipo' <> 'interno' then raise exception 'Só para quem pediu.'; end if;
  return coalesce((select json_agg(x order by x.tem_acesso desc, x.usos desc, x.nome nulls last, x.email) from (
    select coalesce(c.id, -p.id) as id, c.id as contato_id, coalesce(c.nome, p.nome) as nome, coalesce(c.email, p.email) as email,
           coalesce(p.fornecedor, c.fornecedor) as fornecedor, coalesce(c.usos, 0) as usos, p.id is not null as tem_acesso,
           case when adm and p.id is not null then json_build_object('id', p.id, 'ativo', p.ativo, 'ultimo_acesso', p.ultimo_acesso,
             'fornecedor', p.fornecedor, 'travado', p.travado_ate > now()) end as acesso
    from sol_contatos c full join sol_pessoas p on lower(p.email) = c.email
    where coalesce(c.email, p.email) is not null) x), '[]'::json);
end $$;

-- ao criar/editar um acesso, o contato também fica salvo
create or replace function public._sol_pessoa_contato() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.email is not null then
    insert into sol_contatos (nome, email, fornecedor) values (new.nome, lower(new.email), nullif(new.fornecedor, '*'))
    on conflict (email) do update set nome = coalesce(excluded.nome, sol_contatos.nome),
      fornecedor = coalesce(excluded.fornecedor, sol_contatos.fornecedor);
  end if;
  return new;
end $$;
drop trigger if exists sol_pessoas_contato on public.sol_pessoas;
create trigger sol_pessoas_contato after insert or update of nome, email, fornecedor on public.sol_pessoas
  for each row execute function public._sol_pessoa_contato();
insert into public.sol_contatos (nome, email, fornecedor)
select nome, lower(email), nullif(fornecedor, '*') from public.sol_pessoas where email is not null
on conflict (email) do nothing;


-- ---------------------------------------------------------------- pedidos já enviados (só cria os que ainda não existem)
insert into public.sol_cartoes (fornecedor, assunto, descricao, link, status, enviado_em, ultimo_contato, criado_por, ordem)
select v.fornecedor, v.assunto, v.descricao, v.link, 'Enviado', v.enviado::date, v.enviado::date, 'Importado do histórico', v.ordem
from (values
  ('TFleet', 'Apontamento Mobile: viagem com mapa, cercas nos pontos e app único',
   'Proposta para o app de apontamento: tela da viagem com mapa da rota, cercas automáticas nos pontos de parada e um app só (Apontamento + Tracker). Enviada por e-mail; aguardando retorno sobre viabilidade e prazo.',
   null, '2026-11-10', 4),
  ('TFleet', 'Levar o sistema da frota para a infraestrutura da TFleet (pacote de migração)',
   'Pacote com banco, servidor, fluxos n8n, site e app (pacote-tfleet-monitor-frota.zip) mandado por link do Drive, para não depender do servidor de casa. Confira a data em que o e-mail saiu.',
   null, '2026-11-04', 3),
  ('Contratadas (rotas CT)', 'Planilha do efetivo que usa os ônibus das rotas CT',
   'Pedido aos gestores das contratadas: planilha no modelo modelo-efetivo-rotas-CT.xlsx (RFID na 1ª coluna, matrícula, CPF, nome, empresa, gerências e centro de custo). RFID pego na portaria / setor de identificação. Confira a data em que o e-mail saiu.',
   null, '2026-10-30', 2),
  ('TFleet', 'API: gravar endereço e rota do passageiro + hora do embarque, traçado e códigos das linhas',
   'Especificação em PDF (solicitacao-api-tfleet-edicoes.pdf): 2 endpoints novos de gravação (endereço e linha de cadastro do passageiro, pela matrícula) e, na API de leitura, data e hora do embarque, traçado oficial das linhas e a lista dos códigos de linha. Confira a data em que o e-mail saiu.',
   null, '2026-10-29', 1)
) as v(fornecedor, assunto, descricao, link, enviado, ordem)
where not exists (select 1 from public.sol_cartoes c where lower(c.assunto) = lower(v.assunto));
insert into public.sol_historico (cartao_id, quem, tipo, texto)
select id, 'Importado do histórico', 'criou', 'Pedido enviado em ' || to_char(enviado_em, 'DD/MM/YYYY') from public.sol_cartoes c
where not exists (select 1 from public.sol_historico h where h.cartao_id = c.id);


-- sem link do Claude nos cartões importados
update public.sol_cartoes set link = null where criado_por like 'Importado%' and link like 'https://claude.ai/%';
-- documentos que já temos dos pedidos importados
insert into public.sol_anexos (cartao_id, nome, tipo, tamanho, dados, enviado_por)
select c.id, d.nome, d.tipo, length(decode(d.b64, 'base64')), decode(d.b64, 'base64'), 'Importado do histórico'
from (values
  ('API: gravar endereço e rota do passageiro + hora do embarque, traçado e códigos das linhas', 'solicitacao-api-tfleet-edicoes.pdf', 'application/pdf', 'JVBERi0xLjQKJZOMi54gUmVwb3J0TGFiIEdlbmVyYXRlZCBQREYgZG9jdW1lbnQgKG9wZW5zb3VyY2UpCjEgMCBvYmoKPDwKL0YxIDIgMCBSIC9GMiAzIDAgUiAvRjMgNCAwIFIgL0Y0IDUgMCBSCj4+CmVuZG9iagoyIDAgb2JqCjw8Ci9CYXNlRm9udCAvSGVsdmV0aWNhIC9FbmNvZGluZyAvV2luQW5zaUVuY29kaW5nIC9OYW1lIC9GMSAvU3VidHlwZSAvVHlwZTEgL1R5cGUgL0ZvbnQKPj4KZW5kb2JqCjMgMCBvYmoKPDwKL0Jhc2VGb250IC9IZWx2ZXRpY2EtQm9sZCAvRW5jb2RpbmcgL1dpbkFuc2lFbmNvZGluZyAvTmFtZSAvRjIgL1N1YnR5cGUgL1R5cGUxIC9UeXBlIC9Gb250Cj4+CmVuZG9iago0IDAgb2JqCjw8Ci9CYXNlRm9udCAvQ291cmllciAvRW5jb2RpbmcgL1dpbkFuc2lFbmNvZGluZyAvTmFtZSAvRjMgL1N1YnR5cGUgL1R5cGUxIC9UeXBlIC9Gb250Cj4+CmVuZG9iago1IDAgb2JqCjw8Ci9CYXNlRm9udCAvSGVsdmV0aWNhLUJvbGRPYmxpcXVlIC9FbmNvZGluZyAvV2luQW5zaUVuY29kaW5nIC9OYW1lIC9GNCAvU3VidHlwZSAvVHlwZTEgL1R5cGUgL0ZvbnQKPj4KZW5kb2JqCjYgMCBvYmoKPDwKL0NvbnRlbnRzIDEzIDAgUiAvTWVkaWFCb3ggWyAwIDAgNTk1LjI3NTYgODQxLjg4OTggXSAvUGFyZW50IDEyIDAgUiAvUmVzb3VyY2VzIDw8Ci9Gb250IDEgMCBSIC9Qcm9jU2V0IFsgL1BERiAvVGV4dCAvSW1hZ2VCIC9JbWFnZUMgL0ltYWdlSSBdCj4+IC9Sb3RhdGUgMCAvVHJhbnMgPDwKCj4+IAogIC9UeXBlIC9QYWdlCj4+CmVuZG9iago3IDAgb2JqCjw8Ci9Db250ZW50cyAxNCAwIFIgL01lZGlhQm94IFsgMCAwIDU5NS4yNzU2IDg0MS44ODk4IF0gL1BhcmVudCAxMiAwIFIgL1Jlc291cmNlcyA8PAovRm9udCAxIDAgUiAvUHJvY1NldCBbIC9QREYgL1RleHQgL0ltYWdlQiAvSW1hZ2VDIC9JbWFnZUkgXQo+PiAvUm90YXRlIDAgL1RyYW5zIDw8Cgo+PiAKICAvVHlwZSAvUGFnZQo+PgplbmRvYmoKOCAwIG9iago8PAovQ29udGVudHMgMTUgMCBSIC9NZWRpYUJveCBbIDAgMCA1OTUuMjc1NiA4NDEuODg5OCBdIC9QYXJlbnQgMTIgMCBSIC9SZXNvdXJjZXMgPDwKL0ZvbnQgMSAwIFIgL1Byb2NTZXQgWyAvUERGIC9UZXh0IC9JbWFnZUIgL0ltYWdlQyAvSW1hZ2VJIF0KPj4gL1JvdGF0ZSAwIC9UcmFucyA8PAoKPj4gCiAgL1R5cGUgL1BhZ2UKPj4KZW5kb2JqCjkgMCBvYmoKPDwKL0NvbnRlbnRzIDE2IDAgUiAvTWVkaWFCb3ggWyAwIDAgNTk1LjI3NTYgODQxLjg4OTggXSAvUGFyZW50IDEyIDAgUiAvUmVzb3VyY2VzIDw8Ci9Gb250IDEgMCBSIC9Qcm9jU2V0IFsgL1BERiAvVGV4dCAvSW1hZ2VCIC9JbWFnZUMgL0ltYWdlSSBdCj4+IC9Sb3RhdGUgMCAvVHJhbnMgPDwKCj4+IAogIC9UeXBlIC9QYWdlCj4+CmVuZG9iagoxMCAwIG9iago8PAovUGFnZU1vZGUgL1VzZU5vbmUgL1BhZ2VzIDEyIDAgUiAvVHlwZSAvQ2F0YWxvZwo+PgplbmRvYmoKMTEgMCBvYmoKPDwKL0F1dGhvciAoT3BlcmFjYW8gQkRWIC8gVEZsZWV0IC0gSHlkcm8gUGFyYWdvbWluYXMpIC9DcmVhdGlvbkRhdGUgKEQ6MjAyNjEwMjkxNTUwMDUrMDAnMDAnKSAvQ3JlYXRvciAoXCh1bnNwZWNpZmllZFwpKSAvS2V5d29yZHMgKCkgL01vZERhdGUgKEQ6MjAyNjEwMjkxNTUwMDUrMDAnMDAnKSAvUHJvZHVjZXIgKFJlcG9ydExhYiBQREYgTGlicmFyeSAtIFwob3BlbnNvdXJjZVwpKSAKICAvU3ViamVjdCAoRW5kcG9pbnRzIGRlIGF0dWFsaXphY2FvIGRlIGVuZGVyZWNvIGUgcm90YSBkbyBjb2xhYm9yYWRvcikgL1RpdGxlIChTb2xpY2l0YWNhbyBkZSBpbnRlZ3JhY2FvIC0gQVBJIFRGbGVldCkgL1RyYXBwZWQgL0ZhbHNlCj4+CmVuZG9iagoxMiAwIG9iago8PAovQ291bnQgNCAvS2lkcyBbIDYgMCBSIDcgMCBSIDggMCBSIDkgMCBSIF0gL1R5cGUgL1BhZ2VzCj4+CmVuZG9iagoxMyAwIG9iago8PAovRmlsdGVyIFsgL0FTQ0lJODVEZWNvZGUgL0ZsYXRlRGVjb2RlIF0gL0xlbmd0aCAyNTUyCj4+CnN0cmVhbQpHYXVITUNOJjVrKEInaDM1bTE8KlI8OTQrSD91ZiIrQUphIygqMVVEaEpXVCo3XFgxIy9eWnBXRFZBUyJxcWF1Wic/TylRQDpMUkY3I0xhMFNvXDZxLHJVLkxxJjpXNUkocSIwNT5YWmE9YDRVaC9YTlBnK1dvOUpocCxtbWRnSV5yM0JlWz0rJ1A4clxhVVhLPkVoL0xvOClNXD81UEcsS2wxOkYvIyU2I1lVNDUqXnFwRDZAImQyXUpoW3REXDVSX2xhZGQ4aDJoNTcqT11XMF9rJGs1TWNTZ15jalNKSl9hU0xcKiZHWks0NUVQUCI8OjozQkwvYDleWSk0Yjk/JisjaGsoZCVrVjFKKHU7aXMsLD0pJiVyWWptJFQkaihhKDhFNT0oXWVYV2RSTS06VlQjTUEnSCdXNlU8WzpSaUlda1NoUSR1TVI/TFlaK1piSl9lYF4xJlxVa2cuQFQqc0pJVE4wOlpCIUldZURuT3JuVSpGOGswdTQiOkl0SiZ0SE4xJWtrJjQ3ISxVMUpKYVojNU1VSnNePU0nI11BTz1Ubk4rMGh0ZnFAIVNeV0MzVUcuamw/a2NIPDdkYkZZQGQ/ITBJb0dZITo9M0JzLT1fOTA2PiZHWUAzQ3VyUDZPPyZuIl5BYEFDUk8mVStMPUJaYEZQcGIsbWAqaVBfaz1XVUA0YSRDWUFDZkBNKylqTllRKWcjREc9TCcpVSFmUjE9UkwsJEo+M0IsRWg/azYwLlU4P0pfSUdwYDFDTyNlMi9lV0o7K3Q8I2V1KS86TEotNVMnLGw3M1dEMSZUNkFNanUjTCcrOm8nRyY+UGNLOEBAZW4wNFxDJj80Rjo0KC1rMTVuQGZmYWc+UGBoVVEhLWY5RmFcWGNYMjAvZ1MrQW1wW1JjQy0mOTFUJ2UyP2g8PUh0RidHVWlvblc/bTIoWCg1W0dtJGNdbi87YE87IyFmK1lKO1wuYSoxSS0/W3NHWU4uS0R0LmpNMjkrNyZeKTVcbzFzKlVzaTZINCg4MlNBbGtlKmNGYVFnVT4vPCMtLEU9bG44TnEldGpFX2U2OFMtVE81UXUhMi5hXTw1WjREYCJOIXVWKzdkdCVgJEAjSGVeXixiPmxFI1w0LlBeIVtMZDohNjpdN2lDLXVPWickPG4uRz5dQ15EMkB1TDQkKThJTEgoaj1RJF5JVXVwJ2ZBME8kSTByUGdwajwwJEw2KiJLKzVJKHIqWHUkL3ElUkJdJUReVT8iTmV1cjIlNDVTYWNTZEhMIjJVZ1A+WCY4N2QzLllwQnIxVU1KPFVrM0I5U0ZsKm1QSyYtMytfZ0U+dFlSMm1zPmpLKC9FPCdXYzxoajwuaGEncDZpWy0mU01YSDQuKDchcGJAWjg6Y1gubjk8UV0zLTtdRG1LKHBkMHU2QEIoQi1QZmtYXypITnUtN0EnT1lIVDNjQy9RJEEyOnVUOV4tcj47byxjZD04LidyKzhmXDZ0RCs4XHUwLCVpPVw7IU9qWS5XbyZhQl8+JkZucVMlYys9Kz5WK18xKXVzcV9WIlFFMXJOIXVVZU9CblRGQzJzVi4oZkklJkdbMDktRTRuViYmRjFdKzFvPUFPLGc6K2YuJ19VV2RhaEh0SktPSGNRRXMndU01YGZHLCUkUVxbMWlPRVkvPilBUFRBSCxfUzdAVyUlNl1JNVNBIU8sMHM+L1xDUFlTKGxaYDotOz5ASy1VLiMudUBoXzN1Mz4tM2lbV2JwYm9naEpCUzBaY01oMkk7S2JdUUZtJGA7UCNxTWRFcVlIJEpjRllUYWMoTTBXPi9cJWBZOk1sbiRSVW8iPj9YIyVMUWwnKWAqNkRcZ1tCJTM+ZnVpckdBRDUjQGEwbDk/STUva1NOWFBhSUcvaidOJWU2JWNRXGhbNWRaSTBAY0NqRVsvSEA8UjdaNE5wYF5nZC9VKCFXb1tXLTxMcVYiJlMsJit0MWpQL1FWKEhWaWpJZSUnYVdlSnFTS1Bpa1pSU29gIzRLRWE3MSdvc2A2aShaU01lTVx0OG4sLSwrOl5vRF1HTFAvTFQsST09WzBPRlwtVyg0cFNDJklTc2pTVSotSlA/I0c1NT1QbmZwdVx0Z21NXkBeSDZBMnItJ0QoWyhFKCtDcWVqbktXJ0RGZjJdRmRgTDpadDdwYWxkWiFfVk4wWzMyU0hqK0NCY2opWzVFSWUpZktFVjFoS0VMbl5FTlE4KkJdQ05nJ1YwOV5rLnRaRkxjay9YaiNdZS82TlojJmpWP1VlIkFVYWtdRTlzNUFbUGY8LVRwNk1RXVdaPVMrTj5RNnNUXWZsUnVZOVVJJm0wa2R0JmVNSV5ldV4+NGNPR09iTFgqTCZZYCtLdCdSOGokUUVGXUNmKl5CL3QoPis4PUA+M2k/Lyc3KzY6Lmg/VVNWRCdnTUxDYUdJQjhIVyZBN2JGRGxHP0NVclFxaGpAJypmJGk0UHVrRzUnTVhNPGg4cDdbWyUpKSx1MTZvIjlUNG5QZGJSIzNUKT09UCRnakNER1JLTVcnJUkzLCUwQzA8YCVSOjMicG5LbWUxL1Y7QWZRRkM3X01iVW4rcipsW2FdaklsLWZtRiRDLFpAMFtWaiIqWiNeIWomJUZQME5FISIoNkw1amwqNl5RdGN1JXQpUDFfVmlcPkolRjZQMnQjWGA7OU8qdDxTdENlWFwiclpIPywrZ246TFZNak8pJkU6TG5ZNk5STl4tLTUjN0w5UXEuSFJTVFlPLUBlIkRcPTlxbks7X2BmR2JlTGAtUEttKGNfWEhCLUQjczoyTSUmOFNrbj5rTGhAQzEyRlQ5bjQxLV8lS2xmO0A+IzYvUikmPCY9KjgjZClTJzdqNmNSMk85bXA9I2YlcHBdRVxtdDpwSmwvZVo2K109WzY3cWMyND9wb1xgbVBqXFZeajEvLDprN0psWWk5WWM0V2VKPFdZYHBfWUMlPWlQJz1TVUxyaF9XSyRMWTJMLzVIMHFaNjErVE8iIlI6cFNtVm8+cHJSMC9hUypOTEYrLyg4V2BjUVA2Klcwc1pZNGJnVnIqYzlKQGcuUlRwQTVLLlxJaiRWXEVZRzJwNDNGKmM8NTZRaW9VOFldYlUjOjNlVHEyWnIlT0pJb1EzQ0xkLFVCQ3EpQ0hSSC0kLFUpU19Vajk8LC9tKUxhOydJXzw+LCJnI2ZkMW4uIkxEZ1NTKTVEYCclLzlzRihmXy4tITUrTUlZJnNXNCpsIUtVXmZaLjRvTDlnZzxkZEI1My1KPjxSa2ZnJUtBLGsjK19lSiNELURycG5nUyVWY0FDVi9UczNfZDhdNlhHcVEtS0JiUGxvTUc4cDZxVGJ0WTV0JUlCNlFCIllpbGB1NFBCb1BxT1NXUTJjQCVsc00vZ2AkMDd+PmVuZHN0cmVhbQplbmRvYmoKMTQgMCBvYmoKPDwKL0ZpbHRlciBbIC9BU0NJSTg1RGVjb2RlIC9GbGF0ZURlY29kZSBdIC9MZW5ndGggMjIyNQo+PgpzdHJlYW0KR2IhI15EL1w0PiZjVjMqMGVndEcnQVI9a2w+O2U6JDclZ21bRGYhNDNJQ01CNVg7Tl81Mz5vKkw2QXVfTXVOR1xXPjBYPTg2WFtpSnI+YS1Cbmw1PEFmZjdlLG04Vm4rbS4qTiVlKyc6byxlNUwkSGs7Z2NqTzpYJzNtLTg1K1JoTEIiW1gySjQnc0hUYmRsMExyNTBOcy8+aCQhZ1YxTl9DNSgqVGVYYW0kQXVhdGpkREdeMV5bMU5kWS9kPTw8J1kpNi4/QyVfbkpEV11EL2cpYEFgZ045J2EqLUkmRVRgJUxeJkFmKDEtKSVgLmE4VDppWTdNOFI4bXBJOXN1JDIjS0VrL00vOXM0TmpTZlNPcl1YOUFGKShBUz4/SVk/ZlVOViwrLCo6TzQ/XVMrNGM0NG9LbEhsK0ptNFszJ3BtYml1Vys6UjxSK0ptIWFLMFdBcEJuNDoqIVE5MzpRJmwxKEhqYS9VKSEjaFpaa0VhdU1XXDNDbkQ/Vj8jLkdFSF8wYV5ZRy1SM1M+WkoxQG8xRiIiWWFjTXBdUkFgSlxySG9BVTxlSFhiJTJsQl9hMVJSRSFCRUY4ZWgjdEMjQkQ9LkxoIV4nYjAjZ1IqTVBGQnBNLStKOEhkPVF0Q3M/QVk0SklrNE1jcypRb15FcSpyNGEwLlgiUS5zPUlKMnJGWjNicj88Vic+NUZxUEs1cDlyaSRbMD1LcjBbRS8kSD4mJ2IwUW5mYCpETFZJSV1UPl9gL1JSbVs6LzUrW0cjRWU4Tjp1KTxmZV5ZTE5UZj1dSzY6MDtFTWxiY1FFLU9TXHJkaGdLU3A8bUdBIjo+PVRYPktpMjtLXjNSaWZ1J1I9Q1Yvaj9xZTJbZ2chaihVYjRHcFwpRlxyVSwkaV4uKyoySUkpTVQhZG5fZGZeK1YkcHNdUypULzoqLDVrYCM0LGAxRVNoTUJuay8jRlMsJnVFU0BANSVXVTstJ0kxbzRcYjcvRz9AOXF1JGpWNF4mXEk4OWpMdWkhImk+KGZqPVpQXl5vZC1NPSc8SEMyb2A0XmBrXUFuTitXRjNFLWI2MmsiVywzaUImcmNHOjs+LG4pbSghaiVGM3RsPSJkMyI8bmonMlFsRGRnOidSXC9nJG90MHQua1s3VUwwPWZlbidxYiIkQ2ZBbV5GXUdjLXBeXjpeWj05L0Bfc1g+S20nVmViUFhVOy1TaDl1VWpmYTJPJTZsQFpJZS9Wcy82WHArcUhsO2lpMS1vL2RmOTRbU0gkUSVLRmM9Y15SZnElWEIhQyJII11XalNmZDMpLzxqOGUpbEU5NiVEak9dLlZxTkNSaDhzWmo0Vz5ocjU2YVY+bTdoSSZyIi04WF07PnJpdSchclQwKjAyJ2pZVklRIywqPmxMKCQ3Ni5KP2taSkZqSTBfOV03aCovOzhybiFpMyVqQWVIRy9oYEY/PmE9VzB1MVEvMi5jLDIrJSZBN2wyN0IqOVNmI0RkQlVUUlo+UVg+V0w/JHJvY0cjSzwhZk5CJVlQOHI4P1xuZnFcVz1QNzkyMFtrI3Q4TiQiM1c6UC1IQVswTmUqLkskdFozZlMjME9lNyNeIi08P2ZGPSUwUV9VOFp1Wmdlc1NrU1s/MWpOJTsmSCVGdVIsWDNXMF9FMTJENTRFQGFeaW1PXkMmWDBBMFpkTnMsaUdYOiplaCl0LklVUUZgbSNNUVYiNEA7M1Y+OTJjckpQSF9NLVFBOVdUSDFBPTo6RFNkTCc9cTE/VHRRIz9LZU4tSGo8JFJVTCtkRm0yJVVoJkFPO0lVT2VxakBWQWknJ2JZQSs+ZSMqPEIxIWdmR3RWOSZwP3FLMVgyQ1Q9bUw/T2I0dEpTbGp1dTMlZz1kRGRBMVY5O1xNY2wvNCsvYD89ODU1KEQ5c1Q3NCs4ZiYmQSVab1hFLnJcYlFPSiVlXjhjXihwbXVEZFUubFVEUGgyLVBaRy4nPCUyXy5KUkRGRzozajQkOGMkLlppNW0qKDcjbTpIQ0FvTmFaZDJhQl9BW2NyUGx0O1VfQSdiNjlAOE9sTSMvWDs6X1hkaWZudGhWXysrLnBSTDAramo2NS9SSixwOVpMIjNsXVFmSXFwcEFsVk8jZ15ZcyFzXlxjOWc6IUxAcUJtQjBkVWtvSWtALzNQQlFdWTUrbjJaZWssNlNubjtcKkgicjZiRi4wJTRrS10tXU5oRUJsWC9HcVZRUkBSYy9OY1xCJUBqWmpQP24hYC91OSxSbCM+LlFcb0VmZVwnO2tbZ0RRZnEqYTNMZmteXjpqTytxKGpCVDhgUzxRWlpFKF8zS1BLJGRFazRBc0k0JD8pNClTJ24oMCciQ1VlSltUM1soOFU9cTknKGklQHMlTF11QE1ARVxQcThJQy5BcGk4cS5JNi0wWThPYD5GXDxIOl9yUEYwcTotbChxWkkzKz9wN2MlcVxDLE1obTQlI1JfImE+Y2RWUlNGbFMhcVVUTllgbFljX0txOVljKVYsLj5RMVstZy9oc2loUlBUS0RYZ2BESDpqWWEiay9ES25lPmYyJ21oISEybnUqKlQzMVMzQ0EuJ2ldMz05ZkcybUNCNmNDVV9xTSE1KTtzI29cSEFAYjNiTixFbFUnZkZRIlZbOydEVShzNFU+L24tWD1UPW1HcDgwUzona2gkTGpEITlGK2JcUTo4Jk5tK1JxUVw6LVNpWDZRZWRZNSExV0pcXWw0V0FEPmguPFBpPkgkKTgyJzQlRy9rMV4+KHJzclZWTjtWQkNuckoyMjUrSzVQOyEzXz5cUzxlM15bLCFqRyZOX0hdaj5TMF1GU3JXRG5JMFFrZGc5OFZuTCtxYUMwYGNkUUo2LTdrNzNDVT8iaVpHKik/aygiJzE/KmY5ZnRhP1BJcipRZDpgTGNeNGArUiIsamo/T089X1k7cz0rK2kqbz8lN3QxaHEsQC5rLyYxYnJYWm5RbWVkfj5lbmRzdHJlYW0KZW5kb2JqCjE1IDAgb2JqCjw8Ci9GaWx0ZXIgWyAvQVNDSUk4NURlY29kZSAvRmxhdGVEZWNvZGUgXSAvTGVuZ3RoIDE5NjEKPj4Kc3RyZWFtCkdhdUhMRC9cL2UmSDsqKUU8bjhKL0o7M15oWCMlcWkrOiNsVGtpKitxZHBzWSxmWDc+TSUxdFs9Ymx0TSpAWS1XcjZpMFU+SVtCWWhHSkwwa0lFWlwjZTlYUXAxS2xyciVgaT4iVF5xdUVZJCo0SSRoUiNvMUFETTdyJDpma2RWWj8rOjtAJG4sYV1APWZNNHE9WUU4ays5KUtoTEN0TkIkJEFPUlw6O3RLN00tKy0mTkhQWmxdJWs9NGV1RGdnZEpWaEVpaT5APVpZXEthNjlDKTVcakZAMm8kNyxpNCgidU4nX0pTa1hUTW1eUCJFS1ZHNyxUYmVBNDFeK05kSWNYXDE3bmhqKV5ASWhFP0gmblNfLHNqXkEsJTVGTUs9WGwnVEMiTlJLb1IpXVVWZHRuVmszQUU0cz9jQG5ORHBRY0pYcyMxUy1uTEovJ0EnYENHWSg3K01hNXBBKSU5JEVsKVJIYDhjZDg9OSFKX01tZUlXYFJbJGM7JFNrMzBcbjpcUS9SLCdPJkZrJioxSmFuRD4yWjZlVChGR1coby1lLWZxMiRcaEouY0xaYU86akUrNjNEVkJqZ0hrZlpzJC00SUJHPW5lXl91LTk3ZCxmNSlCUl0zZWpFWWtnWTFVUTxnQjNpNTJcYis4J0g7TmQicE5HcUorXkBWLCcvU1xlR103V3FddT9ic1NndTZ1RTEjJ2VeWEkwZFQrI0QnTnA+Q0BWMFlCUys8Rlc+QUhnSStqaEBtMFtDVldsa2xtKDxcPGlUI0Q+O0xCbipaOWFFNkxyTUstaXI2Q29INUtxKiI2Xyw4bWc/cDRgaiUvKzEpVDMwPE1WSUpNJEQoS1lgVi9ALmBPSChIbUA0REtCNSJ0J0wxVFQrcCFqOmAkWiVGIlJdRC11cSREUEI5MnVEP0ZkNWhlSCw6O1dqZEFmcVNRJl1zZUMqc2ZSRVEmMShGUERyazU1cUdnZXRCZzEqOFZuUjRtKmxsRyhSakowUGhOWGxbcVoqO3UqcHIsdTlyci1XVkFlZ2ZgZjREdVwlazs9OT1MRCJUcDE4QEA8azZHRXMrZEZrREYvYzdPUyElMWRlU3BYQ2BIPjY8MC9IcEsmYUZPLkc+K3ItRkdAaVREXU5PQyZzZEpdMjdVa0AtPz9RZ21kZjRsYShsWGlnYW41dU85Uik4XTRTRWJVLjFpLl5ecyJmZk4uJUUpYHNuS20oWjEvLVRrMWAjbjUzWVVcZURSSyVnUnBMJ1BuVCltOEAlKENdZGw3bkQ6cXE9IjFdaE5ZYT9zOExCJUcxIihCOG1PJmA9ZkBMNSk5anEuQ1BFOkUqTml0Wzo/MzRFaDhfLzRZLzduYyYrUVxmO0InUjtqM1hBT0Uqc1EvRDVuLjssJURGV1pVQGUmNyRmXjQ2bUFQNDU3XCQrM2FebiFXanJfTm1WWzE/NW9laGksUDRyVSJYUkpuVV10QXA+YC0yQGErK3R0UXRdYmZtb2ZNJjpBOF5pJU0pQWw/YmRQJDpqNUxLbF5JQGFHXUlrTnA/MTMjbUNWbz1tSjRCI1gqOWJzblpWIS8kdTQ+SEFZMmIwcjhnPmA2dUBPXENHJz5JI0ttcFJLXSY5WXBTVDlvRnIxUCEvT2w+PywlJSRcV0VKOHIpW0dTKmY8bHNbSS1GIUwxVDZZUmVUKV0wLlYjc1M2PmttZS5bYi1JTTszTGtERi1nSnJqTkRAZ1cxTylrJjFeXmdnaDUwLUhtcCQwOUFYSygkOzIyKEstQVswVTInPlRoUT9kYS1eW2ZmZWNBVDlcO05kMzM7K25MXGdgN0MpSyQqXVpAbTRdajNATidpMj9NRFBzVlAwcCFccFhAViFXMTgyKk1iQydIQVxvKXUvITRAYiotOiVQWFozYTJkYC91PCEqSDtYLyg5PDxqcVpNXF1ycmhuOFNNIyFhVmtxJDtwTFlJXUwxPjxiaFJwR2ZHKT8iK0YqI2lqLS5zZjdAZ25dYyRBVVIoSSY8Tk0tb0s8P2JCZ1VLVXUpW0stMytOXDktWWU6MSQjMzFBcDZwV2xhMlliaSUha1U4TmRVZy1GSTxNZDJKIidZOmtrcGplPS8nRjZWdCJFKk5oW3JYa0UxZS1hL1lHK2NmSGQwVWxGOzIxaEcjOitmXzw+WCJlQWZNMnRRRXN1ak5KMXNeM2Y2LDw2SDNWcDI3NGhFXDwmU05RaldvNCVyQidWPmBfP1VkV2xrNC9NKkRpKT9KLDNhS2ZRaDNrTipbXFZcb0NkR1NyVWBCKzMoXE1TZGxSOVpQWChcUUFFZF9RbiIjWHNXPi9eRThfUDxUdD1rLCxhdTYvXGJOYSM8ZnRGc2dtdV4lKFItRGFOWyhwYDJCYUpeNGxwIic6MERZVkhmRSxvMjkoPmk4YiNkSENJY1dkREdSSnRjZWdmczwwOVhmUz8zR3U2JWNBP2xMV2lgVTQmbmc0T2Jna1pvbDY+IT4vKUNeVG81VzBRIkB1ZWN1PmRXUU8hTi5nWjZ0KCxFVCE5M0YuIShzKTomUUZJU28sMjU4IkIzYT1UP202cUg3QXFRSC8zI18kMUY7OWFGbFpobFcoSkhOKydQIkVAdX4+ZW5kc3RyZWFtCmVuZG9iagoxNiAwIG9iago8PAovRmlsdGVyIFsgL0FTQ0lJODVEZWNvZGUgL0ZsYXRlRGVjb2RlIF0gL0xlbmd0aCAxNzY5Cj4+CnN0cmVhbQpHYXVITG1uX3Q1JkgwbV0wamRaX0QvZkYtI3EmYEkqKW9sQyFwJSdhV1lUcHBRRiI4OmYxbyxEcVMuNWRTXy0rW1deLygiK2BVdVtiZT8lLWp1RXEocHVlJUVFPGJwdSFbZCg/MyVjYV9pOnJUS01iPyQ2Kic+NiRnRz1LJ1o8XSwqK1VXJzpuLGFdODQqXi1KZ0teUSpGTV9wSFVDYHFFLzJBJW9TTD9PUGA/UXBfVTZCTFY7KnFINmIjPEwlSSpTZ0RlbzpiS0ImX1M7YVUwUlxRcWdwLz9ZP2YnJGMtak01SSpYTSJAZEkoTGVNUS5XXTNRLUd1QDFxUVhLQk9TQGQjYSxLODgkUVxrbUcmbEQ3SWZfMWduYzNUXlw+VVEiJzxAZ29rWWRFSWA8bSpqbCdzTydgJm4+VTI9XVhKKHAyW0BNNEhsVm9hSVp1PSVbSV5IPzFaOU5iT15eJFIvLlgsVkFMXk5mcyxtZE1NKjsycT5uXi0/SC03TSw4ZmA3ZmFEOXRgQ2NIZF1UZUxzXnFFPmdcQ1FoPiZCZkdJPEpETGQmOiIkKnI2JWBMTykoJzZkZG5dMkg0b2t1JFUpUzgvbSstZVlzUVEsa0EtI0oqKC5pU0wpJCQmcEZLYD86cSsuNFVAJkhxXWJCSEVrbCxvX15JVT84Q3E5MD4yaWUrRVhMdC8kKCEuUFQ1PzElLlIuWl42MGRvZGNNXG8oKT0oYXArLDRIYDQ2K11FTFghNU9LZVlNPXImYEM0VGE4c1lCT2ppIlZsaGJyMyNmMHEhYEFdVkkkKDAsaUpucmhJTCNUQWFlN2IpZzdgR1JfYF9NUjpHbDAtXjlpckdIODFmKHEzWSNmOSlycUoqWTclJ3Q8RiRUPllJQmk6I15tcysybnAhOStHJUUoanNiRElRTmlxZUBcI3QrX08hQF0hKVBeQnA8YTRLIyoidT9fUzxFVGw1b0lqPjAxLTMkNzJwLSRDNmoqUjslYkVPc2FMUzY7SE9BVEssQ2lMPEJWTCJuazI6Ik8oOUlESSVPP1JXa09uN0VuVlNUVlNHbyJBREtlUzs7OnM7XyU/bl43aS8pajthXDkjJTN0LjxTI0g4MUUoNmFrVUoxS1slZ1VjamwoQW5STC0hbVpYaylVJmJWTmxFWS5gJnF1OWA7Mm9uMV9wbmtvSnElRU11SldVKFYmLi1wYz1KNjliJUdjWWFWLDxrb0FuUzEnJiRqby4iXiZHRktlZUliUFRfUUdbZlxIbCpZKEluRSc9OVBedEM2PD9hQ2VJPWB1R2xaUWxPXjE2XFxCXCJISmdZIlJVUlhYVlUrLDtXc15QZTtoOiFobm9KZCQ+cy0+TFlTIzUlIk05S0MhKE5TTFRZYkxtQjhTOk03Zlo+QzozLWNyJFMqUyE8SV9jZDt0YU0/XltqQ15kXVVlPVZxVmRgO3AmUUFwMU0zYF90Y19odWg/Si0iMTBaNEckXFs7ZHReZ2ZXTm5aInQ5dUFPPl5vIUdoKU9SXz5yPmJMJ0wmcFo9ImNJV2M4bElNRDFvRk5sQUhYNEdvOE5SXGVJT2BIblVTTGNSazFEXm84TXFKSkJqJVtqLDlGV15jXilPZDI/MTJwR24qaCtPWiwvKzZka2t0UDsnRj1DSzE3SDI+MUAuKylAXlowbW1WPGhvKSU4OVBxZVxMVUxULyQ5dGNUMlBxZiVeWzVXUnBhXG06OGFVdDBRRTBTb3FGOz9ZXS5ydSJmZTZNVllgY21mWkBuXkg+I3VeJW9ydWZUMlEsXUc8STlbRydnSkA8MEsrbiQoU0JAWDtnNEU3a1FcdF5fTlhCS0RfK0pgJyNhIyJBcUQiPTlAbF5HRjI+PG9lcyVTUDUlNHVwImNfbj41WzFPbTYxLlMmRGRjSCciPUFfZVojPyxEUWZRKydeWUh0OkttRShcLko+Nklkcip1LjNWLjxoSGBuNnE2JSY/LFZYUDltXDwhMUpFcEE0RkptZD9NWmdARWskcFVPXzliTHUnRVRVKSFYXzdQbT1iLGBlUkRwWGJAbGtpPnBuXT9aYlJVXk0nZjUvXjwwaidfRnMxRydaL1ltc1Q1YC08RjdUODJjXyIsXE8vRGtIQTBSLUliOi9nVTsiLnI2RSpTSGE8TnU5Izo9YUxGTT8rIlBibiwzZSgxW01AOGQ3R2xwMm85bVlsQmVNLVwnbkc1Y0U4WjlRYzpNVC8yUzpQRV41biNxTG5fKD1hYDUwSEZJVkNBQz9RbFZwSz5eVUFiVVBSNi9ONjdgJS8sZFAvWC0pXFNpYStqb1M0ZD81NTcmI0A4WG1WM19lNGRmWT49JGVuQShZLUljSE5+PmVuZHN0cmVhbQplbmRvYmoKeHJlZgowIDE3CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDA2MSAwMDAwMCBuIAowMDAwMDAwMTIyIDAwMDAwIG4gCjAwMDAwMDAyMjkgMDAwMDAgbiAKMDAwMDAwMDM0MSAwMDAwMCBuIAowMDAwMDAwNDQ2IDAwMDAwIG4gCjAwMDAwMDA1NjUgMDAwMDAgbiAKMDAwMDAwMDc3MCAwMDAwMCBuIAowMDAwMDAwOTc1IDAwMDAwIG4gCjAwMDAwMDExODAgMDAwMDAgbiAKMDAwMDAwMTM4NSAwMDAwMCBuIAowMDAwMDAxNDU1IDAwMDAwIG4gCjAwMDAwMDE4MzIgMDAwMDAgbiAKMDAwMDAwMTkxMCAwMDAwMCBuIAowMDAwMDA0NTU0IDAwMDAwIG4gCjAwMDAwMDY4NzEgMDAwMDAgbiAKMDAwMDAwODkyNCAwMDAwMCBuIAp0cmFpbGVyCjw8Ci9JRCAKWzxlMjdhYTI1MzFiNDJiOGIyNTBiMjQzMDlkMzhlYmQzMD48ZTI3YWEyNTMxYjQyYjhiMjUwYjI0MzA5ZDM4ZWJkMzA+XQolIFJlcG9ydExhYiBnZW5lcmF0ZWQgUERGIGRvY3VtZW50IC0tIGRpZ2VzdCAob3BlbnNvdXJjZSkKCi9JbmZvIDExIDAgUgovUm9vdCAxMCAwIFIKL1NpemUgMTcKPj4Kc3RhcnR4cmVmCjEwNzg1CiUlRU9GCg=='),
  ('Planilha do efetivo que usa os ônibus das rotas CT', 'modelo-efetivo-rotas-CT.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', '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')
) as d(assunto, nome, tipo, b64)
join public.sol_cartoes c on lower(c.assunto) = lower(d.assunto)
where not exists (select 1 from public.sol_anexos a where a.cartao_id = c.id and a.nome = d.nome);

select 'Quadro de solicitações pronto' as resultado, (select count(*) from public.sol_cartoes) as cartoes;
