-- Monitor Frota: FOTO DE EVIDENCIA obrigatoria para registrar a tratativa do roteador.
-- Como usar: Supabase > SQL Editor > New query > colar tudo > Run. Pode rodar de novo.
-- Depende de roteador-tratativa.sql e roteador-registros.sql ja rodados.

-- 1) bucket publico para as fotos (nomes aleatorios, como o bucket de vistorias)
insert into storage.buckets (id, name, public, file_size_limit)
values ('evidencias-roteador', 'evidencias-roteador', true, 8388608)
on conflict (id) do nothing;

drop policy if exists "pagina envia evidencia" on storage.objects;
create policy "pagina envia evidencia" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'evidencias-roteador');

-- 2) coluna com o link da foto
alter table public.roteador_tratativas add column if not exists evidencia_url text;

-- 3) leitura do uso pelo link: agora devolve a foto
drop function if exists public.roteador_ver(uuid);
create or replace function public.roteador_ver(p_token uuid)
returns table (carro text, ligado timestamptz, desligado timestamptz, mb numeric,
               tratado_em timestamptz, tratado_por text, tratativa text, observacao text, evidencia_url text)
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(e.device_name, ''), e.device_id),
         (select l.ts from events l where l.device_id = e.device_id and l.type = 'hotspot_ligado' and l.ts < e.ts
          order by l.ts desc limit 1),
         e.ts,
         round(nullif(e.detail->>'mb_usados', '')::numeric, 1),
         t.tratado_em, t.tratado_por, t.tratativa, t.observacao, t.evidencia_url
  from roteador_tratativas t join events e on e.id = t.event_id
  where t.token = p_token and t.criado_em > now() - interval '90 days';
$$;
grant execute on function public.roteador_ver(uuid) to anon, authenticated;

-- 4) registrar a tratativa: a foto e OBRIGATORIA (o banco tambem recusa sem ela)
drop function if exists public.roteador_tratar(uuid, text, text, text);
create or replace function public.roteador_tratar(p_token uuid, p_tratativa text, p_por text, p_obs text, p_evidencia text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if p_tratativa not in ('MOTORISTA_ORIENTADO', 'USO_AUTORIZADO', 'PASSAGEIRO', 'FALHA', 'NAO_IDENTIFICADO', 'OUTRO') then
    raise exception 'opcao invalida';
  end if;
  if length(trim(coalesce(p_por, ''))) < 3 then raise exception 'informe quem tratou'; end if;
  if length(trim(coalesce(p_obs, ''))) < 5 then raise exception 'descreva o que foi feito'; end if;
  if p_evidencia is null or p_evidencia not like '%/storage/v1/object/public/evidencias-roteador/%' then
    raise exception 'foto da evidencia e obrigatoria';
  end if;
  update roteador_tratativas
     set tratado_em = now(), tratativa = p_tratativa,
         tratado_por = left(trim(p_por), 120), observacao = left(trim(p_obs), 1000),
         evidencia_url = left(p_evidencia, 500)
   where token = p_token and criado_em > now() - interval '90 days';
  if not found then raise exception 'uso nao encontrado ou link expirado'; end if;
  return 'ok';
end $$;
grant execute on function public.roteador_tratar(uuid, text, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';
