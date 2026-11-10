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

create table if not exists public.sol_config (
  id                int primary key default 1 check (id = 1),
  chave_robo        text not null default encode(extensions.gen_random_bytes(18), 'hex'),
  dias_sem_resposta int not null default 5,
  link_quadro       text not null default 'https://zael20.github.io/painel-mes-tfleet-bdv/solicitacoes.html'
);
insert into public.sol_config (id) values (1) on conflict (id) do nothing;

alter table public.sol_cartoes   enable row level security;   -- sem policy: só pelas funções
alter table public.sol_historico enable row level security;
alter table public.sol_pessoas   enable row level security;
alter table public.sol_sessoes   enable row level security;
alter table public.sol_config    enable row level security;
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
  elsif p_token like 'tfq_%' then
    select pe.* into p from sol_sessoes s join sol_pessoas pe on pe.id = s.pessoa_id
     where s.token = p_token and s.expira_em > now() and pe.ativo;
    if p.id is not null then
      update sol_pessoas set ultimo_acesso = now() where id = p.id;
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
  perform public._central_log(null, null, 'senha_errada', 'solicitacoes');
  return json_build_object('erro', 'Senha incorreta.');
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
  permitidos text[] := case when forn then array['status','responsavel','inicio_em','prazo','entregue_em']
    else array['fornecedor','assunto','descricao','link','responsavel','status','enviado_em','inicio_em','prazo',
               'entregue_em','ultimo_contato','emails','ordem'] end;
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
    ultimo_contato = c.ultimo_contato, emails = c.emails, ordem = c.ordem, atualizado_em = now(),
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
      (select link_quadro from sol_config where id = 1) || '?c=' || c.id))
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

-- ---------------------------------------------------------------- 1º cartão (só se o quadro estiver vazio)
insert into public.sol_cartoes (fornecedor, assunto, descricao, link, status, enviado_em, ultimo_contato, criado_por)
select 'TFleet', 'Apontamento Mobile: viagem com mapa, cercas nos pontos e app único',
       'Proposta enviada por e-mail; aguardando retorno sobre viabilidade e prazo.',
       'https://claude.ai/artifact/DHtAqQ2yVQs1amcJpY8u2w', 'Enviado', date '2026-11-10', date '2026-11-10', 'Importado da planilha'
where not exists (select 1 from public.sol_cartoes);
insert into public.sol_historico (cartao_id, quem, tipo, texto)
select id, 'Importado da planilha', 'criou', 'Proposta enviada à TFleet' from public.sol_cartoes c
where not exists (select 1 from public.sol_historico h where h.cartao_id = c.id);

select 'Quadro de solicitações pronto' as resultado, (select count(*) from public.sol_cartoes) as cartoes;
