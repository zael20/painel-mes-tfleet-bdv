-- Central TFleet: CONTROLE DE ACESSOS (nome completo + senha pessoal, ver/editar por painel)
-- e HISTÓRICO de acessos e edições (quem, quando, onde, qual painel, o que mudou: antes -> depois).
--
-- Como usar: Supabase > SQL Editor > New query > colar tudo > Run. Pode rodar de novo sem problema.
--
-- Como funciona:
--  * Cada pessoa tem uma SENHA PESSOAL (única) e o nome completo. Ela entra na Central só com a senha.
--    A senha fica guardada como hash (ninguém consegue ler depois, nem você: se esquecer, troque).
--  * Ao entrar, o Supabase devolve um token de sessão (vale 30 dias). Os painéis mandam esse token
--    em toda gravação (cabeçalho x-tf-sessao). Os gatilhos no fim do arquivo usam o token para:
--      - registrar quem editou e o que mudou (antes -> depois);
--      - RECUSAR a gravação de quem tem só "ver" naquele painel.
--  * Painéis: monitor, vistoria, ocorrencias, lotacao, otimizacao, roteador. Para cada um: ver e/ou editar.
--  * Administrador vê e mexe em tudo e abre a "Gestão de acessos" na Central.
--    Antes de existir um administrador, a Gestão abre com a SENHA DE GESTORES (a mesma da Lotação).
--  * "Exigir senha pessoal" (chave na Gestão): quando ligada, o código geral 8015 para de abrir a
--    Central e os painéis, e vistoria/ocorrência/config do Monitor só gravam com senha pessoal.
--
-- Depende de: pgcrypto (já usado pela Lotação), lotacao_admin (senha de gestores, lotacao-gestores.sql).

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- tabelas
create table if not exists public.central_acessos (
  id            bigserial primary key,
  nome          text not null,
  senha_hash    text not null unique,
  perms         jsonb not null default '{}'::jsonb,   -- {"vistoria":["ver","editar"],"lotacao":["ver"],...}
  admin         boolean not null default false,
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists public.central_sessoes (
  token      text primary key,
  acesso_id  bigint not null references public.central_acessos(id) on delete cascade,
  criado_em  timestamptz not null default now(),
  expira_em  timestamptz not null,
  ultimo_uso timestamptz not null default now()
);
create index if not exists central_sessoes_acesso on public.central_sessoes (acesso_id);

create table if not exists public.central_acessos_log (
  id        bigserial primary key,
  ts        timestamptz not null default now(),
  acesso_id bigint references public.central_acessos(id) on delete set null,
  nome      text,
  evento    text not null,        -- entrou, abriu, negado, editou, saiu, senha_errada, cadastro, codigo_geral
  painel    text,
  tabela    text,
  registro  text,
  resumo    text,
  dados     jsonb,               -- edição: {"campo": ["antes", "depois"], ...}
  ip        text,
  aparelho  text
);
create index if not exists central_acessos_log_ts on public.central_acessos_log (ts desc);
create index if not exists central_acessos_log_pessoa on public.central_acessos_log (acesso_id, ts desc);

create table if not exists public.central_config (
  id           int primary key default 1 check (id = 1),
  exigir_login boolean not null default false
);
insert into public.central_config (id) values (1) on conflict (id) do nothing;

alter table public.central_acessos     enable row level security;   -- sem policy: ninguém lê pela API,
alter table public.central_sessoes     enable row level security;   -- só pelas funções abaixo
alter table public.central_acessos_log enable row level security;
alter table public.central_config      enable row level security;
revoke all on public.central_acessos, public.central_sessoes, public.central_acessos_log, public.central_config
  from anon, authenticated;

-- ---------------------------------------------------------------- auxiliares (internas)
create or replace function public._central_hash(p text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest('tfc:' || coalesce(p, ''), 'sha256'), 'hex');
$$;

create or replace function public._central_hdr(k text) returns text
language plpgsql stable as $$
begin
  return nullif(current_setting('request.headers', true)::json ->> k, '');
exception when others then return null;
end $$;

-- Pessoa dona do token (sessão válida e pessoa ativa) ou null
create or replace function public._central_pessoa(p_token text) returns public.central_acessos
language sql stable security definer set search_path = public as $$
  select a.* from central_sessoes s join central_acessos a on a.id = s.acesso_id
  where s.token = p_token and s.expira_em > now() and a.ativo
  limit 1;
$$;

-- A pessoa pode <nivel> no painel? nivel 'ver' = abre o painel (ver ou editar marcado); 'editar' = grava.
create or replace function public._central_pode(a public.central_acessos, p_painel text, p_nivel text) returns boolean
language sql stable as $$
  select coalesce(a.admin, false)
      or (p_nivel = 'editar' and coalesce(a.perms -> p_painel, '[]'::jsonb) ? 'editar')
      or (p_nivel <> 'editar' and (coalesce(a.perms -> p_painel, '[]'::jsonb) ?| array['ver', 'editar']));
$$;

-- Usado pela Lotação (gestores_senha_ok): o token de quem tem editar em algum dos painéis vale como senha.
create or replace function public.acesso_token_pode(p_token text, p_paineis text[], p_nivel text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select bool_or(public._central_pode(s.p, x, p_nivel))
                   from (select public._central_pessoa(p_token) as p) s, unnest(p_paineis) x
                   where (s.p).id is not null), false);
$$;

create or replace function public._central_log(p_acesso bigint, p_nome text, p_evento text, p_painel text,
  p_resumo text default null, p_tabela text default null, p_registro text default null, p_dados jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into central_acessos_log (acesso_id, nome, evento, painel, resumo, tabela, registro, dados, ip, aparelho)
  values (p_acesso, p_nome, p_evento, p_painel, left(p_resumo, 500), p_tabela, left(p_registro, 120), p_dados,
          left(split_part(coalesce(public._central_hdr('x-forwarded-for'), ''), ',', 1), 60),
          left(public._central_hdr('user-agent'), 300));
$$;

-- Quem está administrando: token de administrador OU a senha de gestores (só para começar).
create or replace function public._central_admin(p_auth text) returns text
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(
    (select a.nome from public._central_pessoa(p_auth) a where a.id is not null and a.admin),
    (select 'Senha de gestores' from lotacao_admin where id = 1
       and senha_hash = crypt(coalesce(p_auth, ''), senha_hash)));
$$;

revoke execute on function public._central_pessoa(text), public._central_log(bigint, text, text, text, text, text, text, jsonb),
  public._central_admin(text), public.acesso_token_pode(text, text[], text) from public, anon, authenticated;

-- ---------------------------------------------------------------- entrar / painel / sair (públicas)
-- Entrar com a senha pessoal. Devolve {token, nome, perms, admin} ou {erro}.
create or replace function public.acesso_entrar(p_senha text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a central_acessos; tk text;
begin
  if (select count(*) from central_acessos_log where evento = 'senha_errada' and ts > now() - interval '10 minutes') >= 40 then
    return json_build_object('erro', 'Muitas tentativas erradas. Espere 10 minutos.');
  end if;
  select * into a from central_acessos where senha_hash = public._central_hash(trim(p_senha)) and ativo;
  if a.id is null then
    perform public._central_log(null, null, 'senha_errada', 'central');
    return json_build_object('erro', 'Senha incorreta.');
  end if;
  tk := 'tfs_' || encode(gen_random_bytes(24), 'hex');
  insert into central_sessoes (token, acesso_id, expira_em) values (tk, a.id, now() + interval '30 days');
  delete from central_sessoes where expira_em < now();
  perform public._central_log(a.id, a.nome, 'entrou', 'central', 'Entrou na Central');
  return json_build_object('token', tk, 'nome', a.nome, 'perms', a.perms, 'admin', a.admin);
end $$;

-- Cada painel chama ao abrir: confere a sessão, devolve as permissões atuais e registra a abertura.
-- p_painel: central, monitor, vistoria, ocorrencias, lotacao, otimizacao, roteador
create or replace function public.acesso_painel(p_token text, p_painel text, p_pagina text default null) returns json
language plpgsql security definer set search_path = public as $$
declare a central_acessos; pode boolean;
begin
  select * into a from public._central_pessoa(p_token);
  if a.id is null then return json_build_object('erro', 'sessao'); end if;
  update central_sessoes set ultimo_uso = now() where token = p_token;
  pode := p_painel = 'central' or public._central_pode(a, p_painel, 'ver');
  if not exists (select 1 from central_acessos_log where acesso_id = a.id and painel = p_painel
                 and evento in ('abriu', 'negado') and ts > now() - interval '5 minutes') then
    perform public._central_log(a.id, a.nome, case when pode then 'abriu' else 'negado' end, p_painel,
      case when pode then 'Abriu ' else 'Tentou abrir (sem permissão) ' end || coalesce(p_pagina, p_painel));
  end if;
  return json_build_object('nome', a.nome, 'perms', a.perms, 'admin', a.admin, 'pode', pode,
                           'exigir', (select exigir_login from central_config where id = 1));
end $$;

create or replace function public.acesso_sair(p_token text) returns text
language plpgsql security definer set search_path = public as $$
declare a central_acessos;
begin
  select * into a from public._central_pessoa(p_token);
  delete from central_sessoes where token = p_token;
  if a.id is not null then perform public._central_log(a.id, a.nome, 'saiu', 'central', 'Saiu'); end if;
  return 'ok';
end $$;

-- Configuração pública: o código geral (8015) ainda vale?
create or replace function public.acesso_config() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('exigir', exigir_login, 'versao', 1) from central_config where id = 1;
$$;

-- Registro de entrada com o código geral 8015 (enquanto "exigir senha pessoal" estiver desligado).
create or replace function public.acesso_codigo_geral(p_painel text default 'central') returns json
language plpgsql security definer set search_path = public as $$
declare ex boolean := (select exigir_login from central_config where id = 1);
begin
  if not ex and not exists (select 1 from central_acessos_log where evento = 'codigo_geral' and painel = p_painel
                            and aparelho is not distinct from left(public._central_hdr('user-agent'), 300)
                            and ts > now() - interval '5 minutes') then
    perform public._central_log(null, 'Código geral (8015)', 'codigo_geral', p_painel, 'Entrou com o código geral');
  end if;
  return json_build_object('permitido', not ex);
end $$;

grant execute on function public.acesso_entrar(text), public.acesso_painel(text, text, text), public.acesso_sair(text),
  public.acesso_config(), public.acesso_codigo_geral(text) to anon, authenticated;

-- ---------------------------------------------------------------- gestão (administrador)
drop function if exists public.acessos_lista(text);
create or replace function public.acessos_lista(p_auth text)
returns table (id bigint, nome text, perms jsonb, admin boolean, ativo boolean, criado_em timestamptz, ultimo_acesso timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if public._central_admin(p_auth) is null then raise exception 'senha incorreta' using errcode = '28000'; end if;
  return query
    select a.id, a.nome, a.perms, a.admin, a.ativo, a.criado_em,
           (select max(l.ts) from central_acessos_log l where l.acesso_id = a.id and l.evento in ('entrou', 'abriu'))
    from central_acessos a order by a.ativo desc, a.nome;
end $$;

-- Criar (p_id null) ou alterar. p_senha null = mantém a senha atual.
create or replace function public.acesso_salvar(p_auth text, p_id bigint, p_nome text, p_senha text,
  p_perms jsonb, p_admin boolean, p_ativo boolean) returns bigint
language plpgsql security definer set search_path = public as $$
declare quem text := public._central_admin(p_auth); novo bigint; antes central_acessos; limpa jsonb := '{}'::jsonb; k text;
begin
  if quem is null then raise exception 'senha incorreta' using errcode = '28000'; end if;
  if length(trim(coalesce(p_nome, ''))) < 3 then raise exception 'Informe o nome completo.'; end if;
  if p_senha is not null and length(trim(p_senha)) < 4 then raise exception 'A senha precisa ter pelo menos 4 caracteres.'; end if;
  if p_senha is not null and trim(p_senha) = '8015' then raise exception 'Não use 8015 (é o código geral).'; end if;
  if p_id is null and p_senha is null then raise exception 'Defina a senha da pessoa.'; end if;
  -- só guarda painéis/níveis conhecidos
  for k in select unnest(array['monitor', 'vistoria', 'ocorrencias', 'lotacao', 'otimizacao', 'roteador']) loop
    if jsonb_typeof(p_perms -> k) = 'array' then
      limpa := limpa || jsonb_build_object(k, (select coalesce(jsonb_agg(v), '[]'::jsonb)
        from jsonb_array_elements_text(p_perms -> k) v where v in ('ver', 'editar')));
    end if;
  end loop;
  begin
    if p_id is null then
      insert into central_acessos (nome, senha_hash, perms, admin, ativo)
      values (trim(p_nome), public._central_hash(trim(p_senha)), limpa, coalesce(p_admin, false), coalesce(p_ativo, true))
      returning id into novo;
      perform public._central_log(novo, trim(p_nome), 'cadastro', 'central', 'Acesso criado por ' || quem,
        'central_acessos', novo::text, jsonb_build_object('perms', limpa, 'admin', coalesce(p_admin, false)));
    else
      select * into antes from central_acessos where id = p_id;
      if antes.id is null then raise exception 'Acesso não encontrado.'; end if;
      update central_acessos set nome = trim(p_nome), perms = limpa, admin = coalesce(p_admin, false),
             ativo = coalesce(p_ativo, true), atualizado_em = now(),
             senha_hash = case when p_senha is null then senha_hash else public._central_hash(trim(p_senha)) end
       where id = p_id;
      novo := p_id;
      if p_senha is not null or not coalesce(p_ativo, true) then delete from central_sessoes where acesso_id = p_id; end if;
      perform public._central_log(novo, trim(p_nome), 'cadastro', 'central', 'Acesso alterado por ' || quem
          || case when p_senha is not null then ' (senha trocada)' else '' end,
        'central_acessos', novo::text, jsonb_strip_nulls(jsonb_build_object(
          'nome', case when antes.nome <> trim(p_nome) then jsonb_build_array(antes.nome, trim(p_nome)) end,
          'perms', case when antes.perms <> limpa then jsonb_build_array(antes.perms, limpa) end,
          'admin', case when antes.admin <> coalesce(p_admin, false) then jsonb_build_array(antes.admin, coalesce(p_admin, false)) end,
          'ativo', case when antes.ativo <> coalesce(p_ativo, true) then jsonb_build_array(antes.ativo, coalesce(p_ativo, true)) end)));
    end if;
  exception when unique_violation then
    raise exception 'Essa senha já é de outra pessoa. Escolha outra.';
  end;
  return novo;
end $$;

create or replace function public.acesso_remover(p_auth text, p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare quem text := public._central_admin(p_auth); n text;
begin
  if quem is null then raise exception 'senha incorreta' using errcode = '28000'; end if;
  delete from central_acessos where id = p_id returning nome into n;
  if n is not null then perform public._central_log(null, n, 'cadastro', 'central', 'Acesso excluído por ' || quem); end if;
  return 'ok';
end $$;

drop function if exists public.acessos_log(text, integer, bigint);
create or replace function public.acessos_log(p_auth text, p_dias integer default 7, p_acesso bigint default null)
returns table (ts timestamptz, acesso_id bigint, nome text, evento text, painel text, tabela text, registro text,
               resumo text, dados jsonb, ip text, aparelho text)
language plpgsql stable security definer set search_path = public as $$
begin
  if public._central_admin(p_auth) is null then raise exception 'senha incorreta' using errcode = '28000'; end if;
  return query
    select l.ts, l.acesso_id, l.nome, l.evento, l.painel, l.tabela, l.registro, l.resumo, l.dados, l.ip, l.aparelho
    from central_acessos_log l
    where l.ts > now() - make_interval(days => greatest(coalesce(p_dias, 7), 1))
      and (p_acesso is null or l.acesso_id = p_acesso)
    order by l.ts desc limit 3000;
end $$;

create or replace function public.acesso_config_salvar(p_auth text, p_exigir boolean) returns text
language plpgsql security definer set search_path = public as $$
declare quem text := public._central_admin(p_auth);
begin
  if quem is null then raise exception 'senha incorreta' using errcode = '28000'; end if;
  update central_config set exigir_login = coalesce(p_exigir, false) where id = 1;
  perform public._central_log(null, quem, 'cadastro', 'central',
    case when p_exigir then 'Ligou' else 'Desligou' end || ' "exigir senha pessoal"');
  return 'ok';
end $$;

grant execute on function public.acessos_lista(text), public.acesso_salvar(text, bigint, text, text, jsonb, boolean, boolean),
  public.acesso_remover(text, bigint), public.acessos_log(text, integer, bigint), public.acesso_config_salvar(text, boolean)
  to anon, authenticated;

-- ---------------------------------------------------------------- Lotação: token vale como senha de gestores
-- Quem tem "editar" em Lotação ou Otimização entra nas partes com nome sem digitar a senha de gestores.
-- (Se rodar o lotacao-gestores.sql de novo, esta função volta à versão antiga: rode este arquivo de novo depois.)
create or replace function public.gestores_senha_ok(senha text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select senha_hash = crypt(coalesce(senha, ''), senha_hash) from lotacao_admin where id = 1), false)
      or (coalesce(senha, '') like 'tfs\_%' and public.acesso_token_pode(senha, array['lotacao', 'otimizacao'], 'editar'));
$$;
revoke execute on function public.gestores_senha_ok(text) from public, anon, authenticated;

-- ---------------------------------------------------------------- Roteador: histórico dos e-mails
-- Cada uso que entra no resumo diário ganha uma linha em roteador_tratativas na hora do envio
-- (criado_em = quando foi para o e-mail). Antes do resumo (alerta por evento), vale events.alert_sent.
drop function if exists public.roteador_historico(text, integer);
create or replace function public.roteador_historico(p_auth text, p_dias integer default 30)
returns table (enviado_em timestamptz, tipo text, event_id bigint, carro text, ligado timestamptz, desligado timestamptz,
               mb numeric, tratado_em timestamptz, tratado_por text, tratativa text, observacao text, token uuid)
language plpgsql stable security definer set search_path = public as $$
declare a central_acessos; ver boolean; edita boolean; desde timestamptz := now() - make_interval(days => greatest(coalesce(p_dias, 30), 1));
begin
  select * into a from public._central_pessoa(p_auth);
  if a.id is not null then
    ver := public._central_pode(a, 'roteador', 'ver'); edita := public._central_pode(a, 'roteador', 'editar');
  else
    ver := public._central_admin(p_auth) is not null; edita := ver;
  end if;
  if not ver then raise exception 'sem permissao' using errcode = '28000'; end if;
  return query
    select t.criado_em, 'resumo diário'::text, e.id, coalesce(nullif(e.device_name, ''), e.device_id),
           (select l.ts from events l where l.device_id = e.device_id and l.type = 'hotspot_ligado' and l.ts < e.ts
            order by l.ts desc limit 1),
           e.ts, round(nullif(e.detail ->> 'mb_usados', '')::numeric, 1),
           t.tratado_em, t.tratado_por, t.tratativa, t.observacao,
           case when edita then t.token end
    from roteador_tratativas t join events e on e.id = t.event_id
    where t.criado_em >= desde;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'events' and column_name = 'alert_sent') then
    return query execute
      'select e.alert_sent, ''alerta por uso''::text, e.id, coalesce(nullif(e.device_name, ''''), e.device_id), null::timestamptz, e.ts,
              round(nullif(e.detail ->> ''mb_usados'', '''')::numeric, 1), null::timestamptz, null::text, null::text, null::text, null::uuid
       from events e
       where e.type = ''hotspot_desligado'' and e.alert_sent >= $1
         and not exists (select 1 from roteador_tratativas t where t.event_id = e.id)' using desde;
  end if;
end $$;
grant execute on function public.roteador_historico(text, integer) to anon, authenticated;

-- ---------------------------------------------------------------- gatilhos: quem editou e o que mudou
-- Painel de cada tabela (argumento do gatilho). Gravações do n8n (service_role) não entram no histórico.
create or replace function public.central_auditar() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  paineis text[] := string_to_array(tg_argv[0], '|');      -- 'ocorrencias|vistoria' = vale editar em qualquer um
  painel text := paineis[1];
  rigido boolean := coalesce(tg_argv[1], 'nao') = 'sim';   -- respeita "exigir senha pessoal"
  papel text;
  tk text := public._central_hdr('x-tf-sessao');
  a central_acessos;
  vo jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  vn jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  dif jsonb := '{}'::jsonb; k text; reg text; res text;
begin
  begin papel := nullif(current_setting('request.jwt.claims', true), '')::json ->> 'role'; exception when others then papel := null; end;
  papel := coalesce(papel, nullif(current_setting('role', true), 'none'));
  if papel is null or papel = 'service_role' then return coalesce(new, old); end if;   -- SQL Editor / n8n

  if tk is not null then select * into a from public._central_pessoa(tk); end if;
  if a.id is not null and not exists (select 1 from unnest(paineis) x where public._central_pode(a, x, 'editar')) then
    raise exception 'Seu acesso é só para ver (%).', painel using errcode = '42501';
  end if;
  if a.id is null and rigido and (select exigir_login from central_config where id = 1) then
    raise exception 'Entre na Central com sua senha pessoal para gravar.' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(vn) loop
      if k not in ('atualizado_em', 'updated_at') and (vo -> k) is distinct from (vn -> k) then
        dif := dif || jsonb_build_object(k, jsonb_build_array(
          case when length((vo -> k)::text) > 300 then to_jsonb(left((vo ->> k), 300) || '…') else vo -> k end,
          case when length((vn -> k)::text) > 300 then to_jsonb(left((vn ->> k), 300) || '…') else vn -> k end));
      end if;
    end loop;
    if dif = '{}'::jsonb then return new; end if;
  else
    for k in select jsonb_object_keys(coalesce(vn, vo)) loop
      if coalesce(vn, vo) -> k <> 'null'::jsonb then
        dif := dif || jsonb_build_object(k, case when length((coalesce(vn, vo) -> k)::text) > 300
          then to_jsonb(left(coalesce(vn, vo) ->> k, 300) || '…') else coalesce(vn, vo) -> k end);
      end if;
    end loop;
  end if;

  reg := coalesce(coalesce(vn, vo) ->> 'id', coalesce(vn, vo) ->> 'device_id', coalesce(vn, vo) ->> 'event_id',
                  coalesce(vn, vo) ->> 'phone', coalesce(vn, vo) ->> 'empresa', coalesce(vn, vo) ->> 'linha',
                  coalesce(vn, vo) ->> 'chave');
  res := case tg_op when 'INSERT' then 'Incluiu' when 'UPDATE' then 'Alterou' else 'Excluiu' end || ' ' || tg_table_name
      || coalesce(' ' || coalesce(coalesce(vn, vo) ->> 'tag', coalesce(vn, vo) ->> 'device_id'), '')
      || case when tg_op = 'UPDATE' then ': ' || (select string_agg(x, ', ') from jsonb_object_keys(dif) x) else '' end;

  perform public._central_log(a.id, coalesce(a.nome, 'Sem senha pessoal'), 'editou', painel, res, tg_table_name, reg, dif);
  return coalesce(new, old);
end $$;

do $$
declare r record;
begin
  for r in select * from (values
      ('vistorias', 'vistoria', 'sim'), ('ocorrencias', 'ocorrencias|vistoria', 'sim'), ('relatores', 'ocorrencias', 'sim'),
      ('device_config', 'monitor', 'sim'), ('roteador_tratativas', 'roteador', 'nao'),
      ('gestores_empresa', 'lotacao', 'nao'), ('gestores_base', 'lotacao', 'nao'), ('gestores', 'lotacao', 'nao'),
      ('vinculos', 'lotacao', 'nao'), ('rotas_monitoradas', 'lotacao', 'nao'), ('locais_ignorar', 'otimizacao', 'nao')
    ) v(tabela, painel, rigido)
  loop
    if to_regclass('public.' || r.tabela) is not null then
      execute format('drop trigger if exists central_auditoria on public.%I', r.tabela);
      execute format('create trigger central_auditoria after insert or update or delete on public.%I
                      for each row execute function public.central_auditar(%L, %L)', r.tabela, r.painel, r.rigido);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';

-- Teste rápido (opcional): deve devolver {"exigir" : false, "versao" : 1}
-- select public.acesso_config();
