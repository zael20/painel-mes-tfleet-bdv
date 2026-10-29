-- Ocorrencias do WhatsApp: o que o motorista RELATA no grupo, organizado por onibus.
-- Fica no MESMO Supabase do Monitor Frota e da Vistoria, para cruzar as tres fontes.
-- Como usar: Supabase > SQL Editor > New query > colar tudo > Run.
-- Pode rodar de novo sem perder dados. Nao mexe em samples, events, device_config nem vistorias.
--
-- Quem grava: o n8n (no servidor), com a chave SECRETA service_role, chamando a funcao
-- public.registrar_mensagem(). A chave service_role fica so na credencial do n8n, nunca no painel.
-- Quem le e muda status: o painel (chave publica + codigo 8015), igual ao device_config.

-- ---------------------------------------------------------------- numero do onibus padronizado
-- So digitos, sem zeros a esquerda, minimo 2 digitos: "carro 7" -> '07', "065" -> '65'. Igual a vistorias.tag.
create or replace function public.normaliza_tag(t text) returns text
language sql immutable as $$
  select case when coalesce(regexp_replace(coalesce(t,''), '\D', '', 'g'), '') = '' then null
              else lpad(coalesce(nullif(ltrim(regexp_replace(t, '\D', '', 'g'), '0'), ''), '0'), 2, '0') end;
$$;

-- ---------------------------------------------------------------- ocorrencias (1 linha por problema de um onibus)
create table if not exists public.ocorrencias (
  id             bigserial primary key,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  tag            text check (length(tag) between 1 and 12),        -- numero do onibus (mesmo da vistoria); null = IA nao identificou
  categoria      text not null default 'outro' check (categoria in (
                   'carregamento',          -- nao carrega / carrega devagar      -> vistoria item_cabo  / monitor: corrente
                   'abrir_viagem',          -- app BDV nao abre viagem             -> vistoria item_app
                   'contagem_passageiros',  -- nao conta / leitor RFID             -> vistoria item_leitor / monitor: Bluetooth
                   'internet_chip',         -- sem internet, chip                  -> vistoria item_chip  / monitor: dados moveis
                   'celular_defeito',       -- tela, travando, desligando, sumiu   -> vistoria item_celular
                   'suporte',               -- suporte solto/quebrado              -> vistoria item_suporte
                   'som_musica',            -- volume, musica                      -> monitor: eventos de midia/volume
                   'outro')),
  problema       text not null check (length(problema) <= 300),   -- descricao curta feita pela IA
  urgencia       text not null default 'media' check (urgencia in ('baixa','media','alta')),
  status         text not null default 'aberta' check (status in ('aberta','em_andamento','resolvida','descartada')),
  relatado_por   text check (length(relatado_por) <= 80),
  primeira_msg_em timestamptz,
  ultima_msg_em  timestamptz,
  reincidencias  integer not null default 0,                       -- quantas vezes foi relatado de novo enquanto aberta
  solucao        text check (length(solucao) <= 1000),
  resolvido_em   timestamptz,
  resolvido_por  text check (length(resolvido_por) <= 80),
  origem         text not null default 'whatsapp' check (origem in ('whatsapp','manual')),
  confianca      numeric(3,2)                                       -- 0 a 1, o quanto a IA teve certeza
);
-- Historico importado da conversa exportada (sudo servidor retroativo): origem 'retroativo'; sem desfecho no grupo
-- = status 'historico' (aconteceu, mas nao se sabe se foi resolvido; nao conta como aberta).
alter table public.ocorrencias drop constraint if exists ocorrencias_status_check;
alter table public.ocorrencias add constraint ocorrencias_status_check
  check (status in ('aberta','em_andamento','resolvida','descartada','historico'));
alter table public.ocorrencias drop constraint if exists ocorrencias_origem_check;
alter table public.ocorrencias add constraint ocorrencias_origem_check
  check (origem in ('whatsapp','manual','retroativo'));
create index if not exists ocorrencias_tag     on public.ocorrencias (tag, criado_em desc);
create index if not exists ocorrencias_status  on public.ocorrencias (status, ultima_msg_em desc);
-- Nao deixa existir duas ocorrencias ABERTAS do mesmo onibus e mesma categoria (anti-duplicata).
create unique index if not exists ocorrencias_uma_aberta
  on public.ocorrencias (tag, categoria) where status in ('aberta','em_andamento') and tag is not null;

-- ---------------------------------------------------------------- mensagens do grupo (registro bruto, nada se perde)
create table if not exists public.whatsapp_msgs (
  msg_id         text primary key,                                  -- id da mensagem no WhatsApp: reenvio do webhook nao duplica
  recebido_em    timestamptz not null default now(),
  ts             timestamptz not null,                              -- hora da mensagem
  grupo_jid      text,
  autor_nome     text check (length(autor_nome) <= 80),
  autor_jid      text check (length(autor_jid) <= 80),
  tipo           text not null default 'texto' check (tipo in ('texto','audio','video','imagem','documento','outro')),
  texto          text check (length(texto) <= 4000),                -- texto ou legenda
  transcricao    text check (length(transcricao) <= 4000),          -- o que a IA ouviu/viu no audio/video/imagem
  midia_path     text,                                              -- link assinado (1 ano) do arquivo no Storage
  midia_tipo     text,                                              -- mimetype, ex.: audio/ogg
  acao_ia        text check (acao_ia in ('nova','atualiza','resolve','ignorar','erro')),
  ia             jsonb,                                             -- resposta completa da IA, para conferencia
  ocorrencia_id  bigint references public.ocorrencias(id) on delete set null
);
alter table public.whatsapp_msgs add column if not exists midia_tipo text;
create index if not exists whatsapp_msgs_ts  on public.whatsapp_msgs (ts desc);
create index if not exists whatsapp_msgs_oc  on public.whatsapp_msgs (ocorrencia_id, ts);

-- ---------------------------------------------------------------- historico de status (quem mudou, quando)
create table if not exists public.ocorrencia_status_log (
  id             bigserial primary key,
  ocorrencia_id  bigint not null references public.ocorrencias(id) on delete cascade,
  em             timestamptz not null default now(),
  de             text,
  para           text,
  por            text
);

create or replace function public.ocorrencias_ao_mudar() returns trigger
language plpgsql security definer set search_path = public as $$  -- definer: o painel (anon) nao grava direto no log
begin
  new.atualizado_em := now();
  if new.status is distinct from old.status then
    if new.status = 'resolvida' and new.resolvido_em is null then new.resolvido_em := now(); end if;
    if new.status in ('aberta','em_andamento') then new.resolvido_em := null; end if;
    insert into public.ocorrencia_status_log (ocorrencia_id, de, para, por)
    values (new.id, old.status, new.status, coalesce(new.resolvido_por, 'painel'));
  end if;
  return new;
end $$;
drop trigger if exists ocorrencias_ao_mudar on public.ocorrencias;
create trigger ocorrencias_ao_mudar before update on public.ocorrencias
  for each row execute function public.ocorrencias_ao_mudar();

-- ---------------------------------------------------------------- quem relatou (numero do WhatsApp -> nome / matricula)
-- reporter_phone: so digitos com DDI, ex. 5591999998888. Vem do autor_jid (n8n) ou do nome na conversa exportada
-- quando o contato nao estava salvo ("+55 91 99999-8888"). Id interno do WhatsApp (@lid) nao e telefone: fica vazio.
-- Nome e matricula ficam em relatores (1 linha por numero): nomear o numero vale para todas as ocorrencias dele.
-- LGPD: no app, prefira a matricula ao nome.
create or replace function public.normaliza_fone(t text) returns text
language sql immutable as $$
  select case when t is null or t ~* '@(lid|g\.us)' then null
              when length(regexp_replace(split_part(t, '@', 1), '\D', '', 'g')) between 10 and 13
                   and split_part(t, '@', 1) !~ '[A-Za-zÀ-ÿ]'
              then regexp_replace(split_part(t, '@', 1), '\D', '', 'g') end;
$$;
alter table public.ocorrencias add column if not exists reporter_phone text;
create index if not exists ocorrencias_reporter on public.ocorrencias (reporter_phone);

create table if not exists public.relatores (
  phone          text primary key check (phone ~ '^\d{10,13}$'),
  nome           text check (length(nome) <= 80),
  matricula      text check (length(matricula) <= 30),
  atualizado_em  timestamptz not null default now()
);
alter table public.relatores enable row level security;
drop policy if exists "painel le relatores" on public.relatores;
create policy "painel le relatores" on public.relatores for select to anon, authenticated using (true);
drop policy if exists "painel cria relatores" on public.relatores;
create policy "painel cria relatores" on public.relatores for insert to anon, authenticated with check (true);
drop policy if exists "painel muda relatores" on public.relatores;
create policy "painel muda relatores" on public.relatores for update to anon, authenticated using (true) with check (true);
revoke all on public.relatores from anon;
grant select, insert, update on public.relatores to anon, authenticated;

-- ocorrencia criada sem numero (ex.: importador retroativo): tenta pelo nome exibido
create or replace function public.ocorrencias_fone() returns trigger language plpgsql as $$
begin
  if new.reporter_phone is null then new.reporter_phone := public.normaliza_fone(new.relatado_por); end if;
  return new;
end $$;
drop trigger if exists ocorrencias_fone on public.ocorrencias;
create trigger ocorrencias_fone before insert on public.ocorrencias for each row execute function public.ocorrencias_fone();

-- ocorrencias que ja existem: numero da primeira mensagem ligada a ela (ou do nome exibido)
update public.ocorrencias o set reporter_phone = coalesce(
    (select public.normaliza_fone(m.autor_jid) from public.whatsapp_msgs m
      where m.ocorrencia_id = o.id and public.normaliza_fone(m.autor_jid) is not null order by m.ts limit 1),
    public.normaliza_fone(o.relatado_por))
 where o.reporter_phone is null;

-- ---------------------------------------------------------------- horas uteis (tempo de atendimento)
-- Expediente padrao 07:30-17:00, segunda a sexta, horario de Paragominas (America/Belem), sem feriados.
-- Para mudar (ex.: contar sabado): update public.expediente set conta_sabado = true;  feriado: insert into public.feriados.
create table if not exists public.expediente (
  id             smallint primary key default 1 check (id = 1),
  inicio         time not null default '07:30',
  fim            time not null default '17:00',
  conta_sabado   boolean not null default false,
  conta_domingo  boolean not null default false,
  conta_feriado  boolean not null default false
);
insert into public.expediente (id) values (1) on conflict (id) do nothing;
create table if not exists public.feriados (dia date primary key, nome text check (length(nome) <= 80));
alter table public.expediente enable row level security;
alter table public.feriados   enable row level security;
drop policy if exists "painel le expediente" on public.expediente;
create policy "painel le expediente" on public.expediente for select to anon, authenticated using (true);
drop policy if exists "painel le feriados" on public.feriados;
create policy "painel le feriados" on public.feriados for select to anon, authenticated using (true);
revoke all on public.expediente, public.feriados from anon;
grant select on public.expediente, public.feriados to anon, authenticated;

-- Horas de expediente entre dois instantes (ex.: aberta 07:30, resolvida 12:00 do mesmo dia = 4,5 h).
create or replace function public.horas_uteis(p_ini timestamptz, p_fim timestamptz) returns numeric
language sql stable security definer set search_path = public as $$
  select case when p_ini is null or p_fim is null then null when p_fim <= p_ini then 0 else
    round(coalesce(sum(greatest(0, extract(epoch from
        least(p_fim, (d::date + e.fim) at time zone 'America/Belem') - greatest(p_ini, (d::date + e.inicio) at time zone 'America/Belem')))), 0) / 3600.0, 2) end
  from public.expediente e
  cross join generate_series((p_ini at time zone 'America/Belem')::date, (p_fim at time zone 'America/Belem')::date, interval '1 day') d
  where e.id = 1
    and (extract(isodow from d) <= 5 or (extract(isodow from d) = 6 and e.conta_sabado) or (extract(isodow from d) = 7 and e.conta_domingo))
    and (e.conta_feriado or not exists (select 1 from public.feriados f where f.dia = d::date));
$$;
grant execute on function public.horas_uteis(timestamptz, timestamptz) to anon, authenticated;

-- ---------------------------------------------------------------- funcao chamada pelo n8n (1 chamada por mensagem)
-- Entrada (jsonb): msg_id, ts, grupo_jid, autor_nome, autor_jid, tipo, texto, transcricao, midia_path,
--   ia: { acao: nova|atualiza|resolve|ignorar, tag, categoria, problema, urgencia, ocorrencia_id, solucao, confianca }
-- Regras: mensagem repetida e ignorada; "nova"/"atualiza" junta na ocorrencia ABERTA do mesmo onibus+categoria
-- (soma reincidencia) ou cria uma; "resolve" so fecha se a IA tiver confianca >= 0.8.
create or replace function public.registrar_mensagem(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ia      jsonb := coalesce(p->'ia', '{}'::jsonb);
  v_acao  text  := coalesce(ia->>'acao', 'ignorar');
  v_tag   text  := public.normaliza_tag(ia->>'tag');
  v_cat   text  := coalesce(nullif(ia->>'categoria',''), 'outro');
  v_urg   text  := coalesce(nullif(ia->>'urgencia',''), 'media');
  v_conf  numeric := nullif(ia->>'confianca','')::numeric;
  v_ts    timestamptz := coalesce((p->>'ts')::timestamptz, now());
  v_id    bigint;
begin
  if v_cat not in ('carregamento','abrir_viagem','contagem_passageiros','internet_chip','celular_defeito','suporte','som_musica','outro') then v_cat := 'outro'; end if;
  if v_urg not in ('baixa','media','alta') then v_urg := 'media'; end if;

  insert into whatsapp_msgs (msg_id, ts, grupo_jid, autor_nome, autor_jid, tipo, texto, transcricao, midia_path, midia_tipo, acao_ia, ia)
  values (p->>'msg_id', v_ts, p->>'grupo_jid', left(p->>'autor_nome',80), left(p->>'autor_jid',80),
          coalesce(nullif(p->>'tipo',''),'texto'), left(p->>'texto',4000), left(p->>'transcricao',4000),
          p->>'midia_path', p->>'midia_tipo', v_acao, ia)
  on conflict (msg_id) do nothing;
  if not found then return jsonb_build_object('ok', true, 'duplicada', true); end if;

  if v_acao = 'ignorar' or v_acao = 'erro' then
    return jsonb_build_object('ok', true, 'acao', v_acao);
  end if;

  -- acha a ocorrencia aberta: pelo id que a IA indicou, senao por onibus + categoria
  select id into v_id from ocorrencias
   where status in ('aberta','em_andamento')
     and (id = nullif(ia->>'ocorrencia_id','')::bigint or (v_tag is not null and tag = v_tag and categoria = v_cat))
   order by (id = nullif(ia->>'ocorrencia_id','')::bigint) desc nulls last, ultima_msg_em desc
   limit 1;

  if v_acao = 'resolve' then
    if v_id is not null and coalesce(v_conf, 0) >= 0.8 then
      update ocorrencias set status = 'resolvida', resolvido_por = left(p->>'autor_nome',80),
             solucao = coalesce(nullif(ia->>'solucao',''), solucao), ultima_msg_em = v_ts
       where id = v_id;
    end if;
    update whatsapp_msgs set ocorrencia_id = v_id where msg_id = p->>'msg_id';
    return jsonb_build_object('ok', true, 'acao', 'resolve', 'ocorrencia_id', v_id, 'fechou', v_id is not null and coalesce(v_conf,0) >= 0.8);
  end if;

  if v_id is not null then
    update ocorrencias set reincidencias = reincidencias + 1, ultima_msg_em = v_ts,
           urgencia = case when v_urg = 'alta' or urgencia = 'alta' then 'alta'
                           when v_urg = 'media' or urgencia = 'media' then 'media' else 'baixa' end
     where id = v_id;
  else
    insert into ocorrencias (tag, categoria, problema, urgencia, relatado_por, reporter_phone, primeira_msg_em, ultima_msg_em, confianca)
    values (v_tag, v_cat, left(coalesce(nullif(ia->>'problema',''), left(p->>'texto',300), 'sem descricao'),300),
            v_urg, left(p->>'autor_nome',80), public.normaliza_fone(p->>'autor_jid'), v_ts, v_ts, v_conf)
    returning id into v_id;
  end if;
  update whatsapp_msgs set ocorrencia_id = v_id where msg_id = p->>'msg_id';
  return jsonb_build_object('ok', true, 'acao', v_acao, 'ocorrencia_id', v_id);
end $$;
revoke all on function public.registrar_mensagem(jsonb) from public, anon, authenticated;
grant execute on function public.registrar_mensagem(jsonb) to service_role;

-- ---------------------------------------------------------------- permissoes
alter table public.ocorrencias           enable row level security;
alter table public.whatsapp_msgs         enable row level security;
alter table public.ocorrencia_status_log enable row level security;

drop policy if exists "painel le ocorrencias" on public.ocorrencias;
create policy "painel le ocorrencias" on public.ocorrencias for select to anon, authenticated using (true);
drop policy if exists "painel muda ocorrencias" on public.ocorrencias;
create policy "painel muda ocorrencias" on public.ocorrencias for update to anon, authenticated using (true) with check (true);
drop policy if exists "painel cria ocorrencia manual" on public.ocorrencias;
create policy "painel cria ocorrencia manual" on public.ocorrencias for insert to anon, authenticated with check (origem = 'manual');
drop policy if exists "painel le mensagens" on public.whatsapp_msgs;
create policy "painel le mensagens" on public.whatsapp_msgs for select to anon, authenticated using (true);
drop policy if exists "painel le historico" on public.ocorrencia_status_log;
create policy "painel le historico" on public.ocorrencia_status_log for select to anon, authenticated using (true);

revoke all on public.ocorrencias, public.whatsapp_msgs, public.ocorrencia_status_log from anon;
grant select, insert, update on public.ocorrencias to anon, authenticated;
grant usage, select on sequence public.ocorrencias_id_seq to anon, authenticated;
grant select on public.whatsapp_msgs, public.ocorrencia_status_log to anon, authenticated;

-- ---------------------------------------------------------------- midia (audios, videos, imagens do grupo)
-- Bucket PRIVADO: so o n8n (chave secreta) grava. Ao gravar, o n8n gera um link assinado valido por 1 ano,
-- que fica em whatsapp_msgs.midia_path para o painel abrir o audio/video.
-- Limite 16 MB por arquivo (o plano gratis tem 1 GB de Storage no total).
insert into storage.buckets (id, name, public, file_size_limit)
values ('whatsapp-midia', 'whatsapp-midia', false, 16777216)
on conflict (id) do update set public = false, file_size_limit = 16777216;

-- ---------------------------------------------------------------- contexto para a IA (chamado pelo n8n antes do Gemini)
-- Ultimas mensagens do grupo (2 horas) + ocorrencias abertas, para a IA juntar mensagens picadas
-- ("carro 65" + audio) e saber se e caso novo, repeticao ou resolucao. Avisa se a mensagem ja foi registrada.
drop function if exists public.contexto_ia(text);
create or replace function public.contexto_ia(p_grupo text, p_msg_id text default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'duplicada', exists (select 1 from whatsapp_msgs where msg_id = p_msg_id),  -- reenvio: nao gasta a IA de novo
    'mensagens', coalesce((select jsonb_agg(m order by m.ts) from (
        select ts, autor_nome, tipo, left(coalesce(nullif(texto,''), transcricao, ''), 300) as texto, ocorrencia_id
        from whatsapp_msgs where grupo_jid = p_grupo and ts > now() - interval '2 hours' and msg_id not like '%#%'
        order by ts desc limit 12) m), '[]'::jsonb),
    'abertas', coalesce((select jsonb_agg(o order by o.ultima_msg_em desc) from (
        select id, tag, categoria, problema, relatado_por, status, ultima_msg_em
        from ocorrencias where status in ('aberta','em_andamento')
        order by ultima_msg_em desc nulls last limit 60) o), '[]'::jsonb));
$$;
revoke all on function public.contexto_ia(text, text) from public, anon, authenticated;
grant execute on function public.contexto_ia(text, text) to service_role;

-- ---------------------------------------------------------------- baixa automatica pela VISTORIA
-- Ocorrencia (aberta, em andamento ou historico do retroativo) e dada como resolvida quando uma vistoria FEITA DEPOIS
-- do relato, no mesmo onibus, deixou o item correspondente OK, ou NOK mas resolvido na hora:
--   - vistoria nova (coluna pendentes preenchida): o item NOK nao ficou em pendentes;
--   - vistoria antiga (planilha): tem acao que nao e lembrete (TROCAR/PEDIR/TEM QUE/PRECISA/VERIFICAR).
-- som_musica/outro nao tem item no checklist: vale a vistoria OPERANTE sem nenhum NOK.
-- Roda sozinha quando entra/muda uma vistoria e quando entra uma ocorrencia (o retroativo importa casos antigos).
alter table public.ocorrencias add column if not exists vistoria_id uuid;   -- vistoria que deu a baixa (resolvido_por = 'vistoria')

create or replace function public.vistoria_item_da_categoria(p_cat text) returns text
language sql immutable as $$
  select case p_cat when 'carregamento' then 'cabo' when 'abrir_viagem' then 'app' when 'contagem_passageiros' then 'leitor'
                    when 'internet_chip' then 'chip' when 'celular_defeito' then 'celular' when 'suporte' then 'suporte' end;
$$;

create or replace function public.resolver_ocorrencias_por_vistoria(p_tag text default null, p_id bigint default null)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if to_regclass('public.vistorias') is null then return 0; end if;
  with alvo as (
    select o.id, v.id as vid, v.ts as vts,
           left('Vistoria de ' || to_char(v.data_vistoria, 'DD/MM') || ': ' ||
                case when x.item = 'OK' or x.item is null then coalesce(nullif(x.rotulo,'') || ' OK', 'carro OPERANTE')
                     else x.rotulo || ' NOK, resolvido na hora' end ||
                coalesce(' (' || nullif(trim(v.acao),'') || ')', ''), 1000) as txt
    from ocorrencias o
    cross join lateral (
      select vv.* from vistorias vv
      cross join lateral (select case public.vistoria_item_da_categoria(o.categoria)
               when 'cabo' then vv.item_cabo when 'app' then vv.item_app when 'leitor' then vv.item_leitor
               when 'chip' then vv.item_chip when 'celular' then vv.item_celular when 'suporte' then vv.item_suporte end as item,
             case public.vistoria_item_da_categoria(o.categoria)
               when 'cabo' then 'NOK CABO / CARREGADOR' when 'app' then 'NOK APLICATIVO BDV' when 'leitor' then 'NOK LEITOR'
               when 'chip' then 'NOK CHIP' when 'celular' then 'NOK CELULAR' when 'suporte' then 'NOK SUPORTE' end as nok) i
      where vv.tag = o.tag
        and vv.ts >= coalesce(o.primeira_msg_em, o.criado_em)
        and vv.status <> 'NAO_VERIFICADO'
        -- reaberta no painel depois de uma baixa: so uma vistoria posterior a reabertura fecha de novo
        and vv.ts > coalesce((select max(l.em) from ocorrencia_status_log l where l.ocorrencia_id = o.id
                               and l.de = 'resolvida' and l.para in ('aberta','em_andamento')), '-infinity')
        and case
              when i.nok is null then vv.status = 'OPERANTE' and vv.resultado = 'OK'
              when i.item = 'OK' then true
              when i.item = 'NOK' and vv.pendentes is not null then not (i.nok = any(vv.pendentes))
              when i.item = 'NOK' then exists (select 1 from regexp_split_to_table(coalesce(vv.acao,''), '\s*,\s*') a
                                              where a <> '' and upper(a) !~ '^(TROCAR|PEDIR|TEM QUE|PRECISA|VERIFICAR)')
              else false end
      order by vv.ts limit 1) v
    cross join lateral (select case public.vistoria_item_da_categoria(o.categoria)
               when 'cabo' then v.item_cabo when 'app' then v.item_app when 'leitor' then v.item_leitor
               when 'chip' then v.item_chip when 'celular' then v.item_celular when 'suporte' then v.item_suporte end as item,
             case public.vistoria_item_da_categoria(o.categoria)
               when 'cabo' then 'cabo/carregador' when 'app' then 'aplicativo' when 'leitor' then 'leitor'
               when 'chip' then 'chip' when 'celular' then 'celular' when 'suporte' then 'suporte' end as rotulo) x
    where o.status in ('aberta','em_andamento','historico') and o.tag is not null
      and (p_tag is null or o.tag = public.normaliza_tag(p_tag))
      and (p_id is null or o.id = p_id))
  update ocorrencias o set status = 'resolvida', resolvido_por = 'vistoria', resolvido_em = a.vts,
         vistoria_id = a.vid, solucao = coalesce(nullif(o.solucao,''), a.txt)
    from alvo a where o.id = a.id;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.resolver_ocorrencias_por_vistoria(text, bigint) from public, anon, authenticated;
grant execute on function public.resolver_ocorrencias_por_vistoria(text, bigint) to service_role;

create or replace function public.ocorrencias_vistoria_gatilho() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'vistorias' then perform public.resolver_ocorrencias_por_vistoria(new.tag, null);
  else perform public.resolver_ocorrencias_por_vistoria(null, new.id); end if;
  return null;
end $$;
drop trigger if exists ocorrencias_baixa_vistoria on public.ocorrencias;
create trigger ocorrencias_baixa_vistoria after insert on public.ocorrencias
  for each row when (new.status in ('aberta','em_andamento','historico') and new.tag is not null)
  execute function public.ocorrencias_vistoria_gatilho();
do $$ begin
  if to_regclass('public.vistorias') is not null then
    execute 'drop trigger if exists vistoria_baixa_ocorrencias on public.vistorias';
    execute 'create trigger vistoria_baixa_ocorrencias after insert or update on public.vistorias
               for each row execute function public.ocorrencias_vistoria_gatilho()';
  end if;
end $$;
select public.resolver_ocorrencias_por_vistoria() as ocorrencias_baixadas_pela_vistoria;   -- passada unica no que ja existe

-- ---------------------------------------------------------------- cruzamento: RELATO x MONITOR x VISTORIA
-- Para cada ocorrencia: ultimo sinal do monitor daquele onibus e ultima vistoria (com o item ligado a categoria).
-- O monitor identifica o onibus por device_name (numero digitado no admin); comparamos pela tag padronizada.
-- Se a tabela vistorias ainda nao existir, a view sai sem as colunas de vistoria; rode este arquivo de novo depois.
-- Colunas do monitor que nao existirem em v_last_sample (versao antiga do schema) saem vazias (null).
do $$
declare v_vist boolean := to_regclass('public.vistorias') is not null;
        v_mon  text;
begin
  select string_agg(case when c.column_name is not null then 'm.' || x.col else 'null::' || x.tipo end || ' as ' || x.apelido,
                    E',\n           ' order by x.ordem)
    into v_mon
    from (values (1, 'device_id', 'text', 'mon_device_id'), (2, 'ts', 'timestamptz', 'mon_ultimo_sinal'),
                 (3, 'battery_pct', 'integer', 'mon_bateria'), (4, 'plugged', 'boolean', 'mon_na_tomada'),
                 (5, 'current_ma', 'integer', 'mon_corrente_ma'), (6, 'bt_connected', 'text', 'mon_bt_conectado'),
                 (7, 'mobile_data_on', 'boolean', 'mon_dados_moveis'), (8, 'app_version', 'text', 'mon_versao_app'))
         as x(ordem, col, tipo, apelido)
    left join information_schema.columns c
      on c.table_schema = 'public' and c.table_name = 'v_last_sample' and c.column_name = x.col;
  execute 'drop view if exists public.v_ocorrencias_cruzadas';
  execute format($v$
    create view public.v_ocorrencias_cruzadas with (security_invoker = on) as
    select o.*,
           %s
           %s
           ,
           b.bt_amostras, b.bt_min_ligado_tomada, b.bt_min_desligado, b.bt_min_sem_leitor, b.bt_causa,
           case when o.categoria in ('carregamento','internet_chip') then 'alta'
                when o.categoria = 'contagem_passageiros' then
                  case when b.bt_causa = 'bluetooth_desligado' then 'baixa'
                       when o.problema ~* '(lent|devagar|demor)' then 'media' else 'alta' end
                when o.categoria = 'suporte' then 'media'
                when o.categoria = 'celular_defeito' then
                  case when o.problema ~* '(n[aã]o liga|desligad|apagad|sumi|morto|sem sinal de vida)' then 'alta' else 'media' end
                else 'baixa' end as prioridade,
           r.nome      as reporter_nome,        -- nome dado no app; vazio = use relatado_por (nome do WhatsApp)
           r.matricula as reporter_matricula,
           -- horas de expediente do relato ate a baixa (aberta: ate agora)
           public.horas_uteis(coalesce(o.primeira_msg_em, o.criado_em),
                              case when o.status in ('resolvida','descartada') then coalesce(o.resolvido_em, o.atualizado_em)
                                   when o.status = 'historico' then null else now() end) as horas_uteis,
           round(extract(epoch from (case when o.status in ('resolvida','descartada') then coalesce(o.resolvido_em, o.atualizado_em)
                                          when o.status = 'historico' then null else now() end)
                                    - coalesce(o.primeira_msg_em, o.criado_em)) / 86400.0, 1) as dias_corridos
    from public.ocorrencias o
    left join public.relatores r on r.phone = o.reporter_phone
    left join lateral (
      select s.* from public.v_last_sample s
      where o.tag is not null and public.normaliza_tag(s.device_name) = o.tag
      order by s.ts desc limit 1) m on true
    -- "nao registrou passageiro": como o celular do onibus estava nas 18h antes do relato (1 amostra por minuto).
    -- Na tomada = onibus ligado/rodando. Bluetooth desligado nesse periodo = causa provavel.
    left join lateral (
      select count(*)::int as bt_amostras,
             count(*) filter (where s.plugged)::int as bt_min_ligado_tomada,
             count(*) filter (where s.plugged and s.bt_on is false)::int as bt_min_desligado,
             count(*) filter (where s.plugged and s.bt_on and coalesce(s.bt_connected,'') = '')::int as bt_min_sem_leitor,
             case when count(*) = 0 then 'sem_dados'
                  when count(*) filter (where s.plugged and s.bt_on is false) >= 10 then 'bluetooth_desligado'
                  when count(*) filter (where s.plugged and s.bt_on and coalesce(s.bt_connected,'') = '') >= 10 then 'leitor_desconectado'
                  when count(*) filter (where s.plugged) = 0 then 'nao_rodou'
                  else 'bluetooth_ok' end as bt_causa
      from public.samples s
      where o.categoria = 'contagem_passageiros' and m.device_id is not null and s.device_id = m.device_id
        and s.ts between coalesce(o.primeira_msg_em, o.criado_em) - interval '18 hours' and coalesce(o.primeira_msg_em, o.criado_em)
      having o.categoria = 'contagem_passageiros' and m.device_id is not null) b on true
    %s
  $v$,
  v_mon,
  case when v_vist then $c$,
           v.data_vistoria    as vist_data,
           v.status           as vist_status,
           v.resultado        as vist_resultado,
           case o.categoria when 'carregamento' then v.item_cabo when 'abrir_viagem' then v.item_app
                            when 'contagem_passageiros' then v.item_leitor when 'internet_chip' then v.item_chip
                            when 'celular_defeito' then v.item_celular when 'suporte' then v.item_suporte end as vist_item,
           v.acao             as vist_acao,
           v.ocorrencias      as vist_ocorrencias,
           v.ts               as vist_ts,
           -- regra do usuario: acao preenchida = resolvido na hora, exceto lembrete (TROCAR/PEDIR/TEM QUE/PRECISA)
           (coalesce(trim(v.acao),'') <> '' and v.acao !~* '^\s*(TROCAR|PEDIR|TEM QUE|PRECISA)') as vist_resolveu$c$ else '' end,
  case when v_vist then $j$left join lateral (
      select x.* from public.vistorias x
      where x.tag = o.tag order by x.data_vistoria desc, x.ts desc limit 1) v on true$j$ else '' end);
  execute 'grant select on public.v_ocorrencias_cruzadas to anon, authenticated';
end $$;
