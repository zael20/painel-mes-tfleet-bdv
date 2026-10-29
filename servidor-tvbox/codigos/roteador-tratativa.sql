-- Monitor Frota: TRATATIVA do uso de roteador (botao "Registrar tratativa" no resumo diario).
-- Como usar: Supabase > SQL Editor > New query > colar tudo > Run. Pode rodar de novo sem problema.
--
-- Cada uso de roteador que entra no resumo ganha uma linha aqui com um token (link do botao).
-- A pagina roteador-tratativa.html so ve/grava o uso daquele token: quem tratou, o que foi feito
-- e a observacao (evidencia). Sem leitura publica da tabela (os tokens ficam protegidos).

create table if not exists public.roteador_tratativas (
  event_id     bigint primary key references public.events(id) on delete cascade,
  token        uuid not null unique default gen_random_uuid(),
  criado_em    timestamptz not null default now(),
  tratado_em   timestamptz,
  tratado_por  text,
  tratativa    text,          -- MOTORISTA_ORIENTADO, USO_AUTORIZADO, PASSAGEIRO, FALHA, NAO_IDENTIFICADO, OUTRO
  observacao   text
);
create index if not exists roteador_tratativas_pendentes on public.roteador_tratativas (criado_em desc) where tratado_em is null;
alter table public.roteador_tratativas enable row level security;   -- sem policy: so service_role (n8n) e as funcoes abaixo
revoke all on public.roteador_tratativas from anon, authenticated;

-- Dados do uso para a pagina (so pelo token do link)
drop function if exists public.roteador_ver(uuid);
create or replace function public.roteador_ver(p_token uuid)
returns table (carro text, ligado timestamptz, desligado timestamptz, mb numeric,
               tratado_em timestamptz, tratado_por text, tratativa text, observacao text)
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(e.device_name, ''), e.device_id),
         (select l.ts from events l where l.device_id = e.device_id and l.type = 'hotspot_ligado' and l.ts < e.ts
          order by l.ts desc limit 1),
         e.ts,
         round(nullif(e.detail->>'mb_usados', '')::numeric, 1),
         t.tratado_em, t.tratado_por, t.tratativa, t.observacao
  from roteador_tratativas t join events e on e.id = t.event_id
  where t.token = p_token and t.criado_em > now() - interval '90 days';
$$;
grant execute on function public.roteador_ver(uuid) to anon, authenticated;

-- Registrar (ou corrigir) a tratativa
drop function if exists public.roteador_tratar(uuid, text, text, text);
create or replace function public.roteador_tratar(p_token uuid, p_tratativa text, p_por text, p_obs text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if p_tratativa not in ('MOTORISTA_ORIENTADO', 'USO_AUTORIZADO', 'PASSAGEIRO', 'FALHA', 'NAO_IDENTIFICADO', 'OUTRO') then
    raise exception 'opcao invalida';
  end if;
  if length(trim(coalesce(p_por, ''))) < 3 then raise exception 'informe quem tratou'; end if;
  if length(trim(coalesce(p_obs, ''))) < 5 then raise exception 'descreva o que foi feito'; end if;
  update roteador_tratativas
     set tratado_em = now(), tratativa = p_tratativa,
         tratado_por = left(trim(p_por), 120), observacao = left(trim(p_obs), 1000)
   where token = p_token and criado_em > now() - interval '90 days';
  if not found then raise exception 'uso nao encontrado ou link expirado'; end if;
  return 'ok';
end $$;
grant execute on function public.roteador_tratar(uuid, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';
