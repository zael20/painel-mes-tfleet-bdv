-- Monitor Frota: REGISTROS de uso de roteador (aba "Uso no roteador" do painel).
-- Como usar: Supabase > SQL Editor > New query > colar tudo > Run. Pode rodar de novo sem problema.
-- Depende de roteador-tratativa.sql (tabela roteador_tratativas) ja rodado.
--
-- Mostra so usos COM consumo de MB (sem MB nao e evidencia: desligar o roteador sozinho nao conta).
-- Junta cada desligamento com o ligamento anterior do mesmo carro (ate 24 h antes) e com a tratativa.
-- Colunas novas: carro, motorista_sugerido (preenchido pelo fluxo do n8n) e os dois controles de e-mail
-- (enviado / aberto). Quem preenche email_aberto_em e o fluxo de rastreio, em outra etapa.

alter table public.roteador_tratativas
  add column if not exists carro              text,
  add column if not exists motorista_sugerido text,
  add column if not exists email_enviado_em   timestamptz,
  add column if not exists email_aberto_em    timestamptz;

drop function if exists public.roteador_registros(int, numeric);
create or replace function public.roteador_registros(p_dias int default 30, p_min_mb numeric default 0)
returns table (event_id bigint, carro text, ligado timestamptz, desligado timestamptz, minutos int,
               mb numeric, motorista_sugerido text, email_enviado_em timestamptz, email_aberto_em timestamptz,
               tratado_em timestamptz, tratado_por text, tratativa text, observacao text)
language sql stable security definer set search_path = public as $$
  select e.id,
         coalesce(nullif(e.device_name, ''), e.device_id),
         l.ts,
         e.ts,
         case when l.ts is null then null else round(extract(epoch from (e.ts - l.ts)) / 60)::int end,
         round(nullif(e.detail->>'mb_usados', '')::numeric, 1),
         t.motorista_sugerido,
         t.email_enviado_em,
         t.email_aberto_em,
         t.tratado_em,
         t.tratado_por,
         t.tratativa,
         t.observacao
  from events e
  left join lateral (
    select x.ts
      from events x
     where x.device_id = e.device_id
       and x.type = 'hotspot_ligado'
       and x.ts < e.ts
       and x.ts > e.ts - interval '24 hours'
     order by x.ts desc
     limit 1
  ) l on true
  left join roteador_tratativas t on t.event_id = e.id
  where e.type = 'hotspot_desligado'
    and e.ts > now() - make_interval(days => greatest(p_dias, 1))
    and nullif(e.detail->>'mb_usados', '')::numeric >= greatest(p_min_mb, 0.0001)
  order by e.ts desc;
$$;
grant execute on function public.roteador_registros(int, numeric) to anon, authenticated;

notify pgrst, 'reload schema';
