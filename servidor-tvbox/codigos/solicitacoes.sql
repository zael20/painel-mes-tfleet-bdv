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
-- nível do acesso: ver (só acompanha), comentar (acompanha, comenta e cobra resposta), editar (tudo do fornecedor)
alter table public.sol_pessoas add column if not exists nivel text not null default 'editar';
alter table public.sol_pessoas drop constraint if exists sol_pessoas_nivel_chk;
alter table public.sol_pessoas add constraint sol_pessoas_nivel_chk check (nivel in ('ver', 'comentar', 'editar'));

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
        'admin', a.admin, 'edita', a.admin or coalesce(a.perms->'solicitacoes', '[]'::jsonb) ? 'editar',
        'comenta', a.admin or coalesce(a.perms->'solicitacoes', '[]'::jsonb) ? 'editar', 'nivel', 'editar');
    end if;
  elsif p_token like 'tfg_%' then
    if exists (select 1 from sol_sessoes_gestor where token = p_token and expira_em > now()) then
      return jsonb_build_object('nome', 'Senha de gestores', 'tipo', 'interno', 'fornecedor', null,
        'admin', true, 'edita', true, 'comenta', true, 'nivel', 'editar');
    end if;
  elsif p_token like 'tfq_%' then
    select pe.* into p from sol_sessoes s join sol_pessoas pe on pe.id = s.pessoa_id
     where s.token = p_token and s.expira_em > now() and pe.ativo;
    if p.id is not null then
      update sol_pessoas set ultimo_acesso = now() where id = p.id;
      if p.fornecedor = '*' then     -- acesso interno (pessoa da casa): vê e edita tudo, sem administrar
        return jsonb_build_object('nome', p.nome, 'tipo', 'interno', 'fornecedor', null, 'admin', false,
          'edita', p.nivel = 'editar', 'comenta', p.nivel <> 'ver', 'nivel', p.nivel);
      end if;
      return jsonb_build_object('nome', p.nome, 'tipo', 'fornecedor', 'fornecedor', p.fornecedor,
        'admin', false, 'edita', p.nivel = 'editar', 'comenta', p.nivel <> 'ver', 'nivel', p.nivel);
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

drop function if exists public.sol_comentar(text, bigint, text);
-- p_cobrar = também manda o comentário por e-mail para quem recebe os avisos do cartão (cobrar resposta)
create or replace function public.sol_comentar(p_token text, p_id bigint, p_texto text, p_cobrar boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token); c sol_cartoes; forn boolean := q->>'tipo' = 'fornecedor'; para text[];
begin
  if not coalesce((q->>'comenta')::boolean, (q->>'edita')::boolean) then raise exception 'Seu acesso é só para acompanhar.'; end if;
  if coalesce(trim(p_texto), '') = '' then raise exception 'Escreva o comentário.'; end if;
  select * into c from sol_cartoes where id = p_id;
  if c.id is null or (forn and lower(c.fornecedor) <> lower(q->>'fornecedor')) then
    raise exception 'Cartão não encontrado.';
  end if;
  insert into sol_historico (cartao_id, quem, tipo, texto)
    values (p_id, (q->>'nome') || case when forn then ' (' || (q->>'fornecedor') || ')' else '' end,
            'comentario', case when p_cobrar then '📣 Cobrou resposta: ' else '' end || left(trim(p_texto), 4000));
  if p_cobrar then
    para := array(select distinct lower(trim(x)) from unnest(c.emails) x where x like '%@%');
    if coalesce(array_length(para, 1), 0) = 0 then
      raise exception 'Este cartão não tem e-mails nos avisos. Coloque pelo menos um para poder cobrar.';
    end if;
    insert into sol_emails (cartao_id, para, assunto, corpo, criado_por)
    values (c.id, para, 'Aguardando retorno: ' || c.assunto,
      'Olá,' || E'\n\n' || trim(p_texto) || E'\n\n' ||
      'Demanda: ' || c.assunto || E'\n' || 'Status: ' || c.status ||
      case when c.prazo is not null then E'\n' || 'Prazo: ' || to_char(c.prazo, 'DD/MM/YYYY') else '' end ||
      E'\n\n' || 'Enviado por ' || (q->>'nome') || ' pelo quadro de demandas.', q->>'nome');
  end if;
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
  public.sol_comentar(text, bigint, text, boolean), public.sol_remover(text, bigint),
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

drop function if exists public.sol_pedido_decidir(text, bigint, boolean);
-- p_nivel: ver | comentar | editar (vazio = editar quando veio de repasse, ver quando a pessoa pediu sozinha)
create or replace function public.sol_pedido_decidir(p_token text, p_id bigint, p_aprovar boolean, p_nivel text default null) returns json
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
  loop  -- código de 4 números que ninguém usa
    senha := lpad(((get_byte(gen_random_bytes(1), 0) * 256 + get_byte(gen_random_bytes(1), 0)) % 10000)::text, 4, '0');
    h := public._central_hash('solpin:' || senha);
    i := i + 1;
    exit when i > 200 or not exists (select 1 from sol_pessoas where senha_hash in (h, public._central_hash('sol:' || senha)));
  end loop;
  select id into pid from sol_pessoas where lower(email) = p.email and lower(fornecedor) = lower(p.fornecedor);
  if pid is null then
    insert into sol_pessoas (nome, fornecedor, email, senha_hash, nivel) values (p.nome, p.fornecedor, p.email, h,
      coalesce(p_nivel, case when p.cartao_id is null then 'ver' else 'editar' end)) returning id into pid;
  else
    update sol_pessoas set senha_hash = h, ativo = true, nome = p.nome, nivel = coalesce(p_nivel, nivel) where id = pid;
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
        'Para atualizar o andamento (status, datas, prazo e recados), abra o link abaixo, clique em "Entrar para atualizar" e digite o seu código de acesso:' || E'\n\n' ||
        '    Código: {{SENHA}}' || E'\n\n' ||
        'Se quiser, peça ao Mizael para trocar o código pelos 4 últimos números do seu celular.' || E'\n\n' ||
        'O código é pessoal: não compartilhe. Você vê só as demandas de ' || p.fornecedor || '.',
        q->>'nome', senha, true) returning id into eid;
    insert into sol_historico (cartao_id, quem, tipo, texto) values (c.id, q->>'nome', 'aviso',
      'Aprovou o acesso de ' || p.nome || ' (código enviado por e-mail)');
  else   -- pediu pela tela de entrada (sem cartão): manda o código mesmo assim
    insert into sol_emails (cartao_id, para, assunto, corpo, criado_por, segredo, interno)
      values (null, array[p.email], 'Seu acesso ao quadro de demandas',
        'Olá, ' || p.nome || '.' || E'\n\n' ||
        'O seu acesso ao quadro de demandas foi aprovado. Abra o link abaixo e digite o seu código de acesso:' || E'\n\n' ||
        '    Código: {{SENHA}}' || E'\n\n' ||
        'O código é pessoal: não compartilhe. Você vê as demandas de ' || p.fornecedor || '.',
        q->>'nome', senha, true) returning id into eid;
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
  public.sol_pedido_decidir(text, bigint, boolean, text), public.sol_pedidos_avisar(text) to anon, authenticated;

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
    'corpo', replace(e.corpo, '{{SENHA}}', coalesce(e.segredo, '')), 'link', coalesce(public._sol_link(c), (select link_quadro from sol_config where id = 1)), 'processo', c.assunto,
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
  -- (p_email ficou só por compatibilidade: a entrada agora é só com a senha ou o código)
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
  -- fornecedor: só o código de acesso (cada código é de uma pessoa só)
  select * into p from sol_pessoas where ativo and senha_hash in
    (public._central_hash('solpin:' || trim(p_senha)), public._central_hash('sol:' || trim(p_senha))) limit 1;
  if p.id is not null then
    tk := 'tfq_' || encode(gen_random_bytes(24), 'hex');
    insert into sol_sessoes (token, pessoa_id, expira_em) values (tk, p.id, now() + interval '60 days');
    delete from sol_sessoes where expira_em < now();
    perform public._central_log(null, p.nome || ' (' || p.fornecedor || ')', 'entrou', 'solicitacoes', 'Fornecedor entrou no quadro');
    return (jsonb_build_object('token', tk) || public._sol_quem(tk))::json;
  end if;
  perform public._central_log(null, null, 'senha_errada', 'solicitacoes');
  return json_build_object('erro', case when trim(p_senha) = '8015'
    then 'O código geral 8015 não vale aqui. Use sua senha pessoal da Central ou a senha de gestores.'
    else 'Senha ou código incorreto.' end);
end $$;

drop function if exists public.sol_pessoa_salvar(text, bigint, text, text, text, text, boolean);
create or replace function public.sol_pessoa_salvar(p_token text, p_id bigint, p_nome text, p_fornecedor text,
  p_email text, p_senha text, p_ativo boolean, p_nivel text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token, true); novo bigint; h text; e text := lower(trim(coalesce(p_email, '')));
begin
  if coalesce(trim(p_nome), '') = '' or coalesce(trim(p_fornecedor), '') = '' then
    raise exception 'Preencha nome e fornecedor.';
  end if;
  if e !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Preencha o e-mail da pessoa (é para onde vão os avisos).'; end if;
  if exists (select 1 from sol_pessoas where lower(email) = e and id is distinct from p_id) then
    raise exception 'Já existe um acesso com esse e-mail.';
  end if;
  if p_senha is not null and trim(p_senha) <> '' then
    if length(trim(p_senha)) < 4 then raise exception 'O código precisa ter pelo menos 4 números (ex.: 4 últimos do celular).'; end if;
    h := public._central_hash('solpin:' || trim(p_senha));
    if exists (select 1 from sol_pessoas where senha_hash in (h, public._central_hash('sol:' || trim(p_senha))) and id is distinct from p_id) then
      raise exception 'Esse código já é de outra pessoa. Escolha outro.';
    end if;
  end if;
  if p_id is null then
    if h is null then raise exception 'Defina a senha.'; end if;
    insert into sol_pessoas (nome, fornecedor, email, senha_hash, ativo, nivel)
      values (trim(p_nome), trim(p_fornecedor), e, h, coalesce(p_ativo, true), coalesce(p_nivel, 'editar')) returning id into novo;
  else
    update sol_pessoas set nome = trim(p_nome), fornecedor = trim(p_fornecedor), email = e, nivel = coalesce(p_nivel, nivel),
      ativo = coalesce(p_ativo, true), falhas = 0, travado_ate = null,
      senha_hash = coalesce(h, senha_hash) where id = p_id returning id into novo;
    if h is not null or not coalesce(p_ativo, true) then delete from sol_sessoes where pessoa_id = p_id; end if;
  end if;
  perform public._central_log(null, q->>'nome', 'cadastro', 'solicitacoes', 'Acesso de fornecedor: ' || trim(p_nome));
  return novo;
end $$;

grant execute on function public.sol_entrar(text, text) to anon, authenticated;
grant execute on function public.sol_pessoa_salvar(text, bigint, text, text, text, text, boolean, text) to anon, authenticated;

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
             'fornecedor', p.fornecedor, 'nivel', p.nivel, 'travado', p.travado_ate > now()) end as acesso
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
-- (os documentos dos pedidos importados ficam em solicitacoes-documentos.sql)

-- ---------------------------------------------------------------- pedir acesso pela tela de entrada
alter table public.sol_emails alter column cartao_id drop not null;
create or replace function public.sol_pedir_acesso(p_nome text, p_email text, p_empresa text, p_mensagem text default null) returns text
language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(coalesce(p_email, '')));
begin
  if coalesce(trim(p_nome), '') = '' or coalesce(trim(p_empresa), '') = '' then raise exception 'Preencha nome, e-mail e empresa.'; end if;
  if e !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;
  if (select count(*) from sol_pedidos_acesso where criado_em > now() - interval '1 hour' and pedido_por = 'Pela tela de entrada') >= 20 then
    raise exception 'Muitos pedidos agora. Tente de novo mais tarde.';
  end if;
  if exists (select 1 from sol_pedidos_acesso where lower(email) = e and status = 'pendente') then
    return 'Seu pedido já está com o responsável. Quando for aprovado, o código chega no seu e-mail.';
  end if;
  insert into sol_pedidos_acesso (fornecedor, nome, email, mensagem, pedido_por)
    values (left(trim(p_empresa), 80), left(trim(p_nome), 120), e, nullif(left(trim(coalesce(p_mensagem, '')), 500), ''), 'Pela tela de entrada');
  return 'Pedido enviado. Quando for aprovado, o código de acesso chega no seu e-mail.';
end $$;
grant execute on function public.sol_pedir_acesso(text, text, text, text) to anon, authenticated;

select 'Quadro de solicitações pronto' as resultado, (select count(*) from public.sol_cartoes) as cartoes;
