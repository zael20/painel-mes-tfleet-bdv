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
  status         text not null default 'aberta' check (status in ('aberta','em_andamento','resolvida','descartada','aguardando_carro','aguardando_teste')),
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
-- 'aguardando_carro' (06/11): relato do WhatsApp sem numero de carro valido. Nao e chamado aberto ainda: o fluxo pergunta
-- o numero ao motorista e, quando o numero chega (ou e corrigido no painel), passa sozinha para 'aberta'.
-- 'aguardando_teste' (11/11): "nao registra passageiro": o sistema mandou o passo a passo (fechar e abrir o app BDV) e
-- espera o motorista dizer se deu certo. "Nao deu" ou sem resposta = vira 'aberta'. "Deu certo" = resolvida.
alter table public.ocorrencias drop constraint if exists ocorrencias_status_check;
alter table public.ocorrencias add constraint ocorrencias_status_check
  check (status in ('aberta','em_andamento','resolvida','descartada','historico','aguardando_carro','aguardando_teste'));
alter table public.ocorrencias
  add column if not exists procedimento_status text,      -- pendente | enviado | deu_certo | nao_deu | sem_resposta | erro
  add column if not exists procedimento_em     timestamptz,
  add column if not exists procedimento_msg_id text,      -- id da mensagem do passo a passo no WhatsApp
  add column if not exists procedimento_erro   text,
  add column if not exists procedimento_etapa  text,      -- monitor (dica do Monitor Frota) | video (passo a passo)
  add column if not exists procedimento_dica   text;      -- o que o Monitor achou (Bluetooth desligado / outro aparelho pareado)
alter table public.ocorrencias drop constraint if exists ocorrencias_origem_check;
alter table public.ocorrencias add constraint ocorrencias_origem_check
  check (origem in ('whatsapp','manual','retroativo'));
create index if not exists ocorrencias_tag     on public.ocorrencias (tag, criado_em desc);
create index if not exists ocorrencias_status  on public.ocorrencias (status, ultima_msg_em desc);
-- Nao deixa existir duas ocorrencias ABERTAS do mesmo onibus e mesma categoria (anti-duplicata).
drop index if exists public.ocorrencias_uma_aberta;
create unique index ocorrencias_uma_aberta
  on public.ocorrencias (tag, categoria) where status in ('aberta','em_andamento','aguardando_teste') and tag is not null;

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
alter table public.whatsapp_msgs add column if not exists responde_a text;   -- id da mensagem citada (resposta "em cima" de outra)
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
  -- chegou o numero do carro: o chamado abre de verdade (bateria/tela ja nasce em andamento, como na entrada)
  if new.status = 'aguardando_carro' and new.tag is not null then
    new.status := case when new.procedimento_status in ('pendente','enviado') then 'aguardando_teste'
                       when new.categoria = 'celular_defeito'
                        and new.problema ~* '(bateria inchad|inchad|tela trincad|tela quebrad|trincad|carca[cç]a)'
                       then 'em_andamento' else 'aberta' end;
  end if;
  if new.status is distinct from old.status then
    if new.status = 'resolvida' and new.resolvido_em is null then new.resolvido_em := now(); end if;
    if new.status in ('aberta','em_andamento','aguardando_carro','aguardando_teste') then new.resolvido_em := null; end if;
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
-- Expediente padrao 08:00-17:00, segunda a sexta, horario de Paragominas (America/Belem), sem feriados.
-- Para mudar (ex.: contar sabado): update public.expediente set conta_sabado = true;  feriado: insert into public.feriados.
create table if not exists public.expediente (
  id             smallint primary key default 1 check (id = 1),
  inicio         time not null default '08:00',
  fim            time not null default '17:00',
  conta_sabado   boolean not null default false,
  conta_domingo  boolean not null default false,
  conta_feriado  boolean not null default false
);
insert into public.expediente (id) values (1) on conflict (id) do nothing;
-- 29/10: expediente passou a 08:00-17:00 (pedido do usuario). So troca se ainda estiver no padrao antigo.
alter table public.expediente alter column inicio set default '08:00';
update public.expediente set inicio = '08:00' where id = 1 and inicio = '07:30';
-- Media de tempo de resolucao so conta relatos a partir desta data (o historico antigo foi conferido depois,
-- em lote, e distorce a media). Para mudar: update public.expediente set metricas_desde = '2026-11-01';
alter table public.expediente add column if not exists metricas_desde timestamptz not null default '2026-10-29 00:00-03';
create table if not exists public.feriados (dia date primary key, nome text check (length(nome) <= 80));
alter table public.expediente enable row level security;
alter table public.feriados   enable row level security;
drop policy if exists "painel le expediente" on public.expediente;
create policy "painel le expediente" on public.expediente for select to anon, authenticated using (true);
drop policy if exists "painel le feriados" on public.feriados;
create policy "painel le feriados" on public.feriados for select to anon, authenticated using (true);
revoke all on public.expediente, public.feriados from anon;
grant select on public.expediente, public.feriados to anon, authenticated;

-- Horas de expediente entre dois instantes (ex.: aberta 08:00, resolvida 12:00 do mesmo dia = 4 h).
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

-- ---------------------------------------------------------------- numero do carro em mensagem separada
-- Motorista manda o video/audio e, logo depois (ou antes), "Carro 76" numa mensagem a parte.
-- numero_carro_texto: acha o numero do onibus num texto CURTO ("Carro 76", "76", "onibus 065", "carro n 7");
-- ignora textos longos e horas ("05:05").
-- p_so = true: so aceita mensagem que e APENAS o numero do carro.
drop function if exists public.numero_carro_texto(text);
create or replace function public.numero_carro_texto(t text, p_so boolean default false) returns text
language sql immutable as $$
  select public.normaliza_tag(coalesce(
    substring(t from '(?i)^\s*(?:(?:o|a)\s+)?(?:(?:carro|[oô]nibus|onibus|ve[ií]culo|frota|bus|n[º°o])\.?\s*)?(?:n[º°o]\.?\s*)?(\d{1,4})\s*[.!,]?\s*$'),
    case when not p_so then substring(t from '(?i)(?:carro|[oô]nibus|onibus|ve[ií]culo|frota)\s*(?:n[º°o]\.?\s*)?(\d{1,4})(?![\d:])') end))
  where t is not null and length(trim(t)) <= 60;
$$;

-- Carros que existem: os que ja tiveram vistoria ou viagem na API TFleet (60 dias). Evita abrir chamado de carro
-- que nao existe (ex.: a IA leu "41" do nome do contato "Philippians 4:13"). Sem nenhuma vistoria/viagem ainda: aceita tudo.
create or replace function public.frota_lista() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare a text[] := '{}'; b text[] := '{}';
begin
  if to_regclass('public.vistorias') is not null then
    execute 'select coalesce(array_agg(distinct public.normaliza_tag(tag)), ''{}'') from public.vistorias where tag is not null' into a;
  end if;
  if to_regclass('public.viagens') is not null then
    execute 'select coalesce(array_agg(distinct public.normaliza_tag(frota)), ''{}'') from public.viagens
              where frota is not null and data_local > current_date - 60' into b;
  end if;
  return array(select distinct x from unnest(a || b) x where x is not null order by 1);
end $$;
create or replace function public.frota_conhecida(p_tag text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.normaliza_tag(p_tag) is not null
     and (cardinality(l) = 0 or public.normaliza_tag(p_tag) = any(l))
  from (select public.frota_lista() as l) f;
$$;
grant execute on function public.frota_lista(), public.frota_conhecida(text) to anon, authenticated;

-- Poe o numero numa ocorrencia que estava sem carro (p_corrigir = true: troca tambem um numero errado).
-- Se ja existe outra aberta do mesmo carro e problema, junta as duas (mensagens vao para a existente;
-- esta fica descartada apontando para ela). Devolve o id final.
drop function if exists public.vincular_carro(bigint, text);
create or replace function public.vincular_carro(p_oc bigint, p_tag text, p_corrigir boolean default false) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_cat text; v_old text; v_dest bigint;
begin
  select categoria, tag into v_cat, v_old from ocorrencias where id = p_oc and (tag is null or p_corrigir)
     and status in ('aberta','em_andamento','aguardando_carro','aguardando_teste','historico','resolvida');
  if not found or public.normaliza_tag(p_tag) is null then return p_oc; end if;
  if v_old = public.normaliza_tag(p_tag) then return p_oc; end if;
  select id into v_dest from ocorrencias where status in ('aberta','em_andamento','aguardando_teste') and tag = public.normaliza_tag(p_tag)
     and categoria = v_cat and id <> p_oc order by ultima_msg_em desc limit 1;
  if v_dest is null then
    -- numero trocado: o motorista da viagem era do carro errado, procura de novo
    update ocorrencias set tag = public.normaliza_tag(p_tag),
           motorista_viagem = case when v_old is null then motorista_viagem end,
           viagem_linha     = case when v_old is null then viagem_linha end,
           tag_fonte        = case when v_old is null then tag_fonte else 'correcao' end
     where id = p_oc;
    return p_oc;
  end if;
  update whatsapp_msgs set ocorrencia_id = v_dest where ocorrencia_id = p_oc;
  update ocorrencias d set reincidencias = d.reincidencias + 1, ultima_msg_em = greatest(d.ultima_msg_em, o.ultima_msg_em)
    from ocorrencias o where d.id = v_dest and o.id = p_oc;
  update ocorrencias set tag = public.normaliza_tag(p_tag), status = 'descartada', resolvido_por = 'sistema',
         solucao = 'Juntada a ocorrencia #' || v_dest || ' (mesmo carro e problema)' where id = p_oc;
  return v_dest;
end $$;
revoke all on function public.vincular_carro(bigint, text, boolean) from public, anon, authenticated;

-- Painel / CHECK BDV: corrigir ou informar o numero do carro de uma ocorrencia (chave publica).
-- Junta com a ocorrencia aberta do mesmo carro e problema, se houver (em vez de dar erro de duplicada).
-- Devolve {ok, ocorrencia_id (a que ficou), juntou, carro, carro_conhecido}.
create or replace function public.corrigir_carro(p_oc bigint, p_tag text, p_por text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tag text := public.normaliza_tag(p_tag); v_id bigint;
begin
  if v_tag is null or length(v_tag) > 4 then return jsonb_build_object('ok', false, 'erro', 'Numero do carro invalido'); end if;
  if not exists (select 1 from ocorrencias where id = p_oc) then return jsonb_build_object('ok', false, 'erro', 'Ocorrencia nao encontrada'); end if;
  v_id := public.vincular_carro(p_oc, v_tag, true);
  update ocorrencias set tag_fonte = 'painel' where id = p_oc and tag = v_tag and status <> 'descartada';
  if v_id <> p_oc then
    update ocorrencias set solucao = solucao || coalesce(' - por ' || left(nullif(trim(p_por),''), 60), '') where id = p_oc;
  end if;
  return jsonb_build_object('ok', true, 'ocorrencia_id', v_id, 'juntou', v_id <> p_oc, 'carro', v_tag,
                            'carro_conhecido', public.frota_conhecida(v_tag));
end $$;
revoke all on function public.corrigir_carro(bigint, text, text) from public;
grant execute on function public.corrigir_carro(bigint, text, text) to anon, authenticated;

-- Ocorrencia aberta SEM carro do mesmo autor, com mensagem ate 30 min antes/depois de p_ts.
create or replace function public.ocorrencia_sem_carro_do_autor(p_autor text, p_ts timestamptz) returns bigint
language sql stable security definer set search_path = public as $$
  select o.id from ocorrencias o
   where o.status in ('aberta','em_andamento','aguardando_carro') and o.tag is null and coalesce(p_autor,'') <> ''
     and exists (select 1 from whatsapp_msgs m where m.ocorrencia_id = o.id
                  and coalesce(nullif(m.autor_jid,''), m.autor_nome) = p_autor
                  and m.ts between p_ts - interval '30 minutes' and p_ts + interval '30 minutes')
   order by o.ultima_msg_em desc limit 1;
$$;

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
  v_autor text;
  v_num   text;
  v_quoted text := nullif(split_part(coalesce(p->>'quoted_id',''), '#', 1), '');
  v_sem   bigint;
  v_resp  text;
begin
  if v_cat not in ('carregamento','abrir_viagem','contagem_passageiros','internet_chip','celular_defeito','suporte','som_musica','outro') then v_cat := 'outro'; end if;
  if v_urg not in ('baixa','media','alta') then v_urg := 'media'; end if;

  insert into whatsapp_msgs (msg_id, ts, grupo_jid, autor_nome, autor_jid, tipo, texto, transcricao, midia_path, midia_tipo, acao_ia, ia, responde_a)
  values (p->>'msg_id', v_ts, p->>'grupo_jid', left(p->>'autor_nome',80), left(p->>'autor_jid',80),
          coalesce(nullif(p->>'tipo',''),'texto'), left(p->>'texto',4000), left(p->>'transcricao',4000),
          p->>'midia_path', p->>'midia_tipo', v_acao, ia, v_quoted)
  on conflict (msg_id) do nothing;
  if not found then return jsonb_build_object('ok', true, 'duplicada', true); end if;
  v_autor := coalesce(nullif(p->>'autor_jid',''), p->>'autor_nome');
  v_num   := public.numero_carro_texto(p->>'texto', true);   -- mensagem que e so "Carro 76"
  -- carro que nao existe na frota = sem numero (o fluxo pergunta ao motorista em vez de abrir chamado errado)
  if v_tag is not null and not public.frota_conhecida(v_tag) then v_tag := null; end if;
  if v_num is not null and not public.frota_conhecida(v_num) then v_num := null; end if;

  -- resposta ao PASSO A PASSO ("deu certo" / "nao deu"): citando a mensagem do sistema, ou texto curto do mesmo autor ate 3 h depois
  v_resp := public.resposta_procedimento(p->>'texto');
  if v_resp is not null then
    select o.id into v_id from ocorrencias o
     where o.procedimento_status in ('enviado','sem_resposta') and o.status in ('aguardando_teste','aguardando_carro','aberta')
       and (o.procedimento_msg_id = v_quoted
            or (v_quoted is null and length(p->>'texto') <= 40 and o.procedimento_em between v_ts - interval '3 hours' and v_ts
                and exists (select 1 from whatsapp_msgs m where m.ocorrencia_id = o.id
                             and coalesce(nullif(m.autor_jid,''), m.autor_nome) = v_autor)))
     order by (o.procedimento_msg_id = v_quoted) desc nulls last, o.procedimento_em desc limit 1;
    if v_id is not null then
      if v_resp = 'sim' then
        update ocorrencias set status = 'resolvida', resolvido_por = 'motorista', procedimento_status = 'deu_certo',
               solucao = coalesce(nullif(solucao,''), case when procedimento_etapa = 'monitor'
                          then left('Resolvido pelo motorista com a dica do Monitor: ' || coalesce(procedimento_dica, 'Bluetooth'), 1000)
                          else 'Resolvido pelo motorista com o passo a passo (fechou e abriu o app BDV).' end),
               ultima_msg_em = greatest(ultima_msg_em, v_ts)
         where id = v_id;
      elsif (select procedimento_etapa from ocorrencias where id = v_id) = 'monitor'
            and (select nullif(trim(procedimento_video_url), '') from whatsapp_avisos where id = 1) is not null then
        -- a dica do Monitor nao resolveu: manda agora o video do passo a passo (ainda nao abre o chamado)
        update ocorrencias set procedimento_status = 'pendente', procedimento_etapa = 'video', procedimento_em = v_ts,
               ultima_msg_em = greatest(ultima_msg_em, v_ts)
         where id = v_id;
      else
        update ocorrencias set procedimento_status = 'nao_deu', ultima_msg_em = greatest(ultima_msg_em, v_ts),
               status = case when status = 'aguardando_teste' then 'aberta' else status end
         where id = v_id;
      end if;
      update whatsapp_msgs set ocorrencia_id = v_id where msg_id = p->>'msg_id';
      -- "nao deu, carro 84": aproveita o numero
      v_num := coalesce(v_num, public.numero_carro_texto(p->>'texto', false));
      if v_num is not null and public.frota_conhecida(v_num) and (select tag from ocorrencias where id = v_id) is null then
        v_id := public.vincular_carro(v_id, v_num);
      end if;
      return jsonb_build_object('ok', true, 'acao', 'procedimento_' || v_resp, 'ocorrencia_id', v_id);
    end if;
    v_id := null;
  end if;

  -- "Carro 84" mandado EM CIMA (citando) da mensagem do relato ou da pergunta do sistema: vale para aquela ocorrencia,
  -- mesmo que ela ja tenha um numero (corrige o numero errado)
  if v_acao <> 'resolve' and v_quoted is not null then
    select o.id into v_id from ocorrencias o
     where o.status in ('aguardando_carro','aberta','em_andamento','aguardando_teste')
       and (o.pergunta_msg_id = v_quoted or o.procedimento_msg_id = v_quoted
            or exists (select 1 from whatsapp_msgs w where w.ocorrencia_id = o.id and split_part(w.msg_id, '#', 1) = v_quoted))
     order by o.ultima_msg_em desc limit 1;
    -- resposta a pergunta do sistema aceita frase ("e o carro 84"); citando o relato, so o numero
    if v_num is null and v_id is not null and exists (select 1 from ocorrencias where id = v_id and pergunta_msg_id = v_quoted) then
      v_num := public.numero_carro_texto(p->>'texto', false);
      if v_num is not null and not public.frota_conhecida(v_num) then v_num := null; end if;
    end if;
    if v_id is not null and v_num is not null then
      v_id := public.vincular_carro(v_id, v_num, true);
      update ocorrencias set ultima_msg_em = greatest(ultima_msg_em, v_ts) where id = v_id;
      update whatsapp_msgs set ocorrencia_id = v_id where msg_id = p->>'msg_id';
      return jsonb_build_object('ok', true, 'acao', 'vincula_carro', 'ocorrencia_id', v_id);
    end if;
    v_id := null;
  end if;

  -- "Carro 76" mandado DEPOIS do video/audio: completa a ocorrencia sem carro do mesmo autor (nao cria outra)
  if v_acao <> 'resolve' and coalesce(v_tag, v_num) is not null then
    v_id := public.ocorrencia_sem_carro_do_autor(v_autor, v_ts);
    -- so junta se a mensagem e so o numero, ou se a IA apontou essa ocorrencia / o mesmo problema
    if v_id is not null and (v_num is not null or v_id::text = coalesce(ia->>'ocorrencia_id','')
                             or v_cat = (select categoria from ocorrencias where id = v_id)) then
      v_id := public.vincular_carro(v_id, coalesce(v_tag, v_num));
      update ocorrencias set ultima_msg_em = greatest(ultima_msg_em, v_ts) where id = v_id;
      update whatsapp_msgs set ocorrencia_id = v_id where msg_id = p->>'msg_id';
      return jsonb_build_object('ok', true, 'acao', 'vincula_carro', 'ocorrencia_id', v_id);
    end if;
    v_id := null;
  end if;

  -- "Carro 84" logo depois de um relato do mesmo autor que ficou com OUTRO numero que nao aparece em nenhuma
  -- mensagem dele (a IA errou, ou veio da viagem): troca o numero
  if v_acao <> 'resolve' and v_num is not null then
    select o.id into v_id from ocorrencias o
     where o.status in ('aberta','em_andamento','aguardando_teste') and o.tag is not null and o.tag <> v_num
       and coalesce(o.tag_fonte, '') <> 'painel'
       and exists (select 1 from whatsapp_msgs m where m.ocorrencia_id = o.id
                    and coalesce(nullif(m.autor_jid,''), m.autor_nome) = v_autor
                    and m.ts between v_ts - interval '30 minutes' and v_ts + interval '30 minutes')
       and not exists (select 1 from whatsapp_msgs m where m.ocorrencia_id = o.id
                    and (coalesce(m.texto,'') || ' ' || coalesce(m.transcricao,'')) ~ ('(^|\D)0*' || ltrim(o.tag, '0') || '(\D|$)'))
     order by o.ultima_msg_em desc limit 1;
    if v_id is not null then
      v_id := public.vincular_carro(v_id, v_num, true);
      update ocorrencias set ultima_msg_em = greatest(ultima_msg_em, v_ts) where id = v_id;
      update whatsapp_msgs set ocorrencia_id = v_id where msg_id = p->>'msg_id';
      return jsonb_build_object('ok', true, 'acao', 'corrige_carro', 'ocorrencia_id', v_id);
    end if;
  end if;

  -- "Carro 76" mandado ANTES (ou que chegou primeiro: o video demora mais para ser lido pela IA):
  -- problema novo sem carro usa o numero que o mesmo autor mandou ate 30 min antes/depois
  if v_acao = 'nova' and v_tag is null then
    select public.numero_carro_texto(m.texto) into v_tag from whatsapp_msgs m
     where coalesce(nullif(m.autor_jid,''), m.autor_nome) = v_autor and m.msg_id <> p->>'msg_id'
       and m.ts between v_ts - interval '30 minutes' and v_ts + interval '30 minutes' and public.numero_carro_texto(m.texto) is not null
       and public.frota_conhecida(public.numero_carro_texto(m.texto))
     order by abs(extract(epoch from m.ts - v_ts)) limit 1;
  end if;

  if v_acao = 'ignorar' or v_acao = 'erro' then
    return jsonb_build_object('ok', true, 'acao', v_acao);
  end if;

  -- acha a ocorrencia aberta: pelo id que a IA indicou, senao por onibus + categoria, senao (sem numero) a do mesmo
  -- autor que esta aguardando o numero, do mesmo problema (foto nova ilegivel nao abre outra)
  if v_tag is null then v_sem := public.ocorrencia_sem_carro_do_autor(v_autor, v_ts); end if;
  select id into v_id from ocorrencias
   where status in ('aberta','em_andamento','aguardando_carro','aguardando_teste')
     and (id = nullif(ia->>'ocorrencia_id','')::bigint or (v_tag is not null and tag = v_tag and categoria = v_cat)
          or (id = v_sem and categoria = v_cat))
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
    -- a mensagem nova trouxe o numero que faltava
    if v_tag is not null and (select tag from ocorrencias where id = v_id) is null then
      v_id := public.vincular_carro(v_id, v_tag);
    end if;
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

-- passada unica: ocorrencias abertas sem carro que ja tem "Carro NN" do mesmo autor ate 30 min antes/depois
do $$
declare r record; v_num text;
begin
  for r in select o.id, min(m.ts) as ts, min(coalesce(nullif(m.autor_jid,''), m.autor_nome)) as autor
             from ocorrencias o join whatsapp_msgs m on m.ocorrencia_id = o.id
            where o.status in ('aberta','em_andamento','aguardando_carro') and o.tag is null group by o.id loop
    select public.numero_carro_texto(x.texto, true) into v_num from whatsapp_msgs x
     where coalesce(nullif(x.autor_jid,''), x.autor_nome) = r.autor
       and x.ts between r.ts - interval '30 minutes' and r.ts + interval '30 minutes'
       and public.numero_carro_texto(x.texto, true) is not null
       and public.frota_conhecida(public.numero_carro_texto(x.texto, true))
     order by abs(extract(epoch from x.ts - r.ts)) limit 1;
    if v_num is not null then perform public.vincular_carro(r.id, v_num); end if;
  end loop;
end $$;

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
        from ocorrencias where status in ('aberta','em_andamento','aguardando_carro','aguardando_teste')
        order by ultima_msg_em desc nulls last limit 60) o), '[]'::jsonb),
    'frota', to_jsonb(public.frota_lista()));   -- numeros de carro que existem (a IA nao chuta numero fora da lista)
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
    where o.status in ('aberta','em_andamento','aguardando_teste','historico') and o.tag is not null
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
  for each row when (new.status in ('aberta','em_andamento','aguardando_teste','historico') and new.tag is not null)
  execute function public.ocorrencias_vistoria_gatilho();
do $$ begin
  if to_regclass('public.vistorias') is not null then
    execute 'drop trigger if exists vistoria_baixa_ocorrencias on public.vistorias';
    execute 'create trigger vistoria_baixa_ocorrencias after insert or update on public.vistorias
               for each row execute function public.ocorrencias_vistoria_gatilho()';
  end if;
end $$;
select public.resolver_ocorrencias_por_vistoria() as ocorrencias_baixadas_pela_vistoria;   -- passada unica no que ja existe

-- ---------------------------------------------------------------- cruzamento com as VIAGENS da API TFleet (tabela viagens, da lotacao)
-- 1) Ocorrencia sem carro, mas com nome de verdade no WhatsApp ("Francisco"): procura a viagem que esse motorista
--    abriu no dia, na hora do relato. Se for um carro so, a ocorrencia ganha o carro (tag_fonte = 'viagem').
-- 2) Ocorrencia com carro: guarda quem estava dirigindo o carro na hora (motorista_viagem, viagem_linha).
--    O painel/app usa esse nome quando o WhatsApp nao tem nome (".", emoji, so o numero).
-- A API so guarda ~7 dias e a coleta comecou em 26/10: casos mais antigos ficam sem viagem.
alter table public.ocorrencias
  add column if not exists motorista_viagem text,
  add column if not exists viagem_linha     text,
  add column if not exists tag_fonte        text;   -- null = relato/IA; 'viagem' = achado pela viagem do motorista

-- nome sem acento, maiusculo, so letras: "Francisco Chagas 🚍" -> 'FRANCISCO CHAGAS'
create or replace function public.nome_chave(t text) returns text
language sql immutable as $$
  select nullif(trim(regexp_replace(translate(upper(coalesce(t,'')), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ', 'AAAAAEEEEIIIIOOOOOUUUUCN'),
                                   '[^A-Z]+', ' ', 'g')), '');
$$;
-- tem cara de nome? (pelo menos 3 letras e nao e telefone)
create or replace function public.nome_valido(t text) returns boolean
language sql immutable as $$
  select length(coalesce(public.nome_chave(t),'')) >= 3 and coalesce(t,'') !~ '^\s*\+?[\d\s().-]{8,}\s*$';
$$;
-- todas as palavras do nome do WhatsApp (3+ letras) aparecem no nome do motorista da API
create or replace function public.nome_bate(p_whats text, p_api text) returns boolean
language sql immutable as $$
  select coalesce(bool_and(w = any(string_to_array(public.nome_chave(p_api), ' '))), false)
  from unnest(string_to_array(public.nome_chave(p_whats), ' ')) w
  where length(w) >= 3 and w not in ('DAS','DOS','MOTORISTA','MOT','SR','SRA','BUS','ONIBUS');
$$;

create or replace function public.completar_pela_viagem(p_oc bigint) returns void
language plpgsql security definer set search_path = public as $$
declare o record; v_ts timestamptz; v_dia date; v_tag text; n int; v record; v_orig bigint := p_oc;
begin
  if to_regclass('public.viagens') is null then return; end if;
  select * into o from ocorrencias where id = p_oc and status in ('aberta','em_andamento','aguardando_carro','aguardando_teste','historico','resolvida');
  if not found then return; end if;
  v_ts := coalesce(o.primeira_msg_em, o.criado_em);
  v_dia := (v_ts at time zone 'America/Belem')::date;

  -- 1) sem carro: pelo nome de quem relatou
  if o.tag is null and public.nome_valido(o.relatado_por) then
    select count(distinct public.normaliza_tag(x.frota)), min(public.normaliza_tag(x.frota)) into n, v_tag from viagens x
     where x.data_local = v_dia and x.frota is not null and public.nome_bate(o.relatado_por, x.motorista)
       and v_ts between x.saida_ts - interval '30 minutes' and coalesce(x.chegada_ts, x.saida_ts + interval '6 hours') + interval '1 hour';
    if n <> 1 then   -- nenhuma viagem cobrindo a hora: qualquer viagem do motorista no dia, se for um carro so
      select count(distinct public.normaliza_tag(x.frota)), min(public.normaliza_tag(x.frota)) into n, v_tag from viagens x
       where x.data_local = v_dia and x.frota is not null and public.nome_bate(o.relatado_por, x.motorista);
    end if;
    if n = 1 and v_tag is not null then
      p_oc := public.vincular_carro(p_oc, v_tag);
      if p_oc = v_orig then update ocorrencias set tag_fonte = 'viagem' where id = p_oc; end if;
      select * into o from ocorrencias where id = p_oc;
    end if;
  end if;

  -- 2) com carro: quem dirigia o carro na hora do relato (ou a viagem mais perto no mesmo dia, ate 12 h)
  if o.tag is not null and o.motorista_viagem is null then
    select x.motorista, x.linha into v from viagens x
     where x.data_local = v_dia and public.normaliza_tag(x.frota) = o.tag and coalesce(trim(x.motorista),'') <> ''
       and abs(extract(epoch from x.saida_ts - v_ts)) < 12 * 3600
     order by (v_ts between x.saida_ts - interval '30 minutes' and coalesce(x.chegada_ts, x.saida_ts + interval '6 hours') + interval '1 hour') desc,
              abs(extract(epoch from x.saida_ts - v_ts))
     limit 1;
    if found then
      update ocorrencias set motorista_viagem = left(v.motorista, 80), viagem_linha = left(v.linha, 80) where id = o.id;
    end if;
  end if;
end $$;
revoke all on function public.completar_pela_viagem(bigint) from public, anon, authenticated;

create or replace function public.ocorrencias_viagem_gatilho() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if tg_table_name = 'ocorrencias' then
    perform public.completar_pela_viagem(new.id);
  else   -- chegou/atualizou viagem: tenta as ocorrencias daquele dia que ainda estao sem carro ou sem motorista
    for r in select id from ocorrencias
              where (tag is null or (motorista_viagem is null and tag = public.normaliza_tag(new.frota)))
                and (coalesce(primeira_msg_em, criado_em) at time zone 'America/Belem')::date = new.data_local loop
      perform public.completar_pela_viagem(r.id);
    end loop;
  end if;
  return null;
end $$;
drop trigger if exists ocorrencias_viagem on public.ocorrencias;
create trigger ocorrencias_viagem after insert or update of tag on public.ocorrencias
  for each row when (new.tag is null or new.motorista_viagem is null)
  execute function public.ocorrencias_viagem_gatilho();
do $$ begin
  if to_regclass('public.viagens') is not null then
    execute 'drop trigger if exists viagem_completa_ocorrencias on public.viagens';
    execute 'create trigger viagem_completa_ocorrencias after insert or update of frota, motorista, saida_ts, chegada_ts on public.viagens
               for each row execute function public.ocorrencias_viagem_gatilho()';
  end if;
end $$;
-- passada unica no que ja existe
do $$ declare r record; begin
  for r in select id from public.ocorrencias where tag is null or motorista_viagem is null loop
    perform public.completar_pela_viagem(r.id);
  end loop;
end $$;

-- ---------------------------------------------------------------- regras automaticas do usuario (29/10)
-- 1) Bateria inchada / tela trincada: ja nasce "em andamento" (nao se resolve na hora; prioridade baixa na view).
create or replace function public.ocorrencias_regras_entrada() returns trigger language plpgsql as $$
begin
  -- 0a) "Nao registra passageiro" (11/11): antes de abrir, o sistema manda o passo a passo e espera a resposta
  if new.status = 'aberta' and new.origem = 'whatsapp' and public.procedimento_aplica(new.categoria, new.problema)
     and coalesce((select a.procedimento_ligado from public.whatsapp_avisos a where a.id = 1), false) then
    new.procedimento_status := 'pendente';
    new.status := case when new.tag is null then 'aguardando_carro' else 'aguardando_teste' end;
    return new;
  end if;
  -- 0) Relato do WhatsApp sem numero do carro: nao abre o chamado; fica aguardando o numero (06/11)
  if new.status = 'aberta' and new.tag is null and new.origem = 'whatsapp' then
    new.status := 'aguardando_carro';
    return new;
  end if;
  if new.status = 'aberta' and new.categoria = 'celular_defeito'
     and new.problema ~* '(bateria inchad|inchad|tela trincad|tela quebrad|trincad|carca[cç]a)' then
    new.status := 'em_andamento';
  end if;
  return new;
end $$;
drop trigger if exists ocorrencias_regras_entrada on public.ocorrencias;
create trigger ocorrencias_regras_entrada before insert on public.ocorrencias
  for each row execute function public.ocorrencias_regras_entrada();

-- 2) "Nao esta lendo / contando passageiro": se a API TFleet mostra uma viagem do carro que SAIU DEPOIS do relato
--    com pelo menos 3 passageiros registrados, o leitor voltou a funcionar (ex.: ligaram o Bluetooth) -> resolvida.
--    Leitor LENTO (lento/devagar/demora) nao fecha assim: continua aberta, prioridade media.
-- Quais relatos a API pode fechar (11/11): contagem de passageiros (menos leitor LENTO), app que nao abre/registra
-- viagem, e celular/outro que fala de registrar/passageiro/cracha. Bateria inchada / tela trincada nunca.
create or replace function public.api_fecha_categoria(p_cat text, p_problema text) returns boolean
language sql immutable as $$
  select coalesce(p_problema, '') !~* '(bateria inchad|inchad|tela trincad|tela quebrad|trincad|carca[cç]a)'
     and case when p_cat = 'contagem_passageiros' then coalesce(p_problema, '') !~* '(lent|devagar|demor)'
              when p_cat = 'abrir_viagem' then true
              when p_cat in ('celular_defeito','outro') then coalesce(p_problema, '') ~* '(registr|passageir|crach|leitor|cart[aã]o)'
              else false end;
$$;
create or replace function public.resolver_contagem_pela_api(p_tag text default null, p_id bigint default null)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if to_regclass('public.viagens') is null then return 0; end if;
  with alvo as (
    select o.id, v.saida_ts, v.ocupacao, v.linha
    from ocorrencias o
    cross join lateral (
      select x.* from viagens x
      where public.normaliza_tag(x.frota) = o.tag and x.saida_ts > coalesce(o.primeira_msg_em, o.criado_em)
        and coalesce(x.ocupacao, 0) >= 3
        -- reaberta no painel: so vale viagem depois da reabertura
        and x.saida_ts > coalesce((select max(l.em) from ocorrencia_status_log l where l.ocorrencia_id = o.id
                                    and l.de = 'resolvida' and l.para in ('aberta','em_andamento')), '-infinity')
      order by x.saida_ts limit 1) v
    where o.status in ('aberta','em_andamento','aguardando_teste','historico') and o.tag is not null
      and public.api_fecha_categoria(o.categoria, o.problema)
      and (p_tag is null or o.tag = public.normaliza_tag(p_tag)) and (p_id is null or o.id = p_id))
  update ocorrencias o set status = 'resolvida', resolvido_por = 'api', resolvido_em = a.saida_ts,
         procedimento_status = case when o.procedimento_status in ('pendente','enviado') then 'sem_resposta' else o.procedimento_status end,
         solucao = coalesce(nullif(o.solucao,''), left('Fechada automaticamente: o relato era que ' ||
                   case when o.categoria = 'abrir_viagem' and o.problema !~* '(registr|passageir|crach|leitor|cart[aã]o)'
                        then 'o app não abria ou não registrava a viagem' else 'o carro não registrava passageiros' end ||
                   ', e a API TFleet mostra que ele voltou a registrar em ' ||
                   to_char(a.saida_ts at time zone 'America/Belem', 'DD/MM "às" HH24:MI') ||
                   ' (' || a.ocupacao || ' passageiros' || coalesce(', ' || a.linha, '') || ').', 1000))
    from alvo a where o.id = a.id;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.resolver_contagem_pela_api(text, bigint) from public, anon, authenticated;

create or replace function public.contagem_api_gatilho() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'viagens' then perform public.resolver_contagem_pela_api(new.frota, null);
  else perform public.resolver_contagem_pela_api(null, new.id); end if;
  return null;
end $$;
drop trigger if exists ocorrencias_contagem_api on public.ocorrencias;
-- tambem quando o carro chega depois (aguardando_carro -> aberta) ou o painel corrige o carro/categoria
create trigger ocorrencias_contagem_api after insert or update of tag, status, categoria on public.ocorrencias
  for each row when (new.tag is not null and new.status in ('aberta','em_andamento','aguardando_teste','historico'))
  execute function public.contagem_api_gatilho();
do $$ begin
  if to_regclass('public.viagens') is not null then
    execute 'drop trigger if exists viagem_fecha_contagem on public.viagens';
    execute 'create trigger viagem_fecha_contagem after insert or update of ocupacao, saida_ts on public.viagens
               for each row when (coalesce(new.ocupacao, 0) >= 3) execute function public.contagem_api_gatilho()';
  end if;
end $$;
select public.resolver_contagem_pela_api() as ocorrencias_fechadas_pela_api;   -- passada unica no que ja existe

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
           b.bt_amostras, b.bt_min_ligado_tomada, b.bt_min_desligado, b.bt_min_sem_leitor, b.bt_causa, bd.bt_desde,
           -- observacao automatica do Monitor Frota para o app/painel mostrar junto da ocorrencia
           case b.bt_causa
             when 'bluetooth_desligado' then 'Monitor Frota: provavelmente o Bluetooth do celular estava desligado' ||
                  coalesce(' desde ' || to_char(bd.bt_desde at time zone 'America/Belem', 'DD/MM HH24:MI'), '') ||
                  ' (' || b.bt_min_desligado || ' min na tomada com Bluetooth desligado nas 18h antes do relato), por isso o leitor não registrou.'
             when 'leitor_desconectado' then 'Monitor Frota: Bluetooth ligado, mas o leitor RFID estava desconectado' ||
                  coalesce(' desde ' || to_char(bd.bt_desde at time zone 'America/Belem', 'DD/MM HH24:MI'), '') ||
                  ' (' || b.bt_min_sem_leitor || ' min nas 18h antes do relato). Conferir pareamento e bateria do leitor.'
             when 'nao_rodou' then 'Monitor Frota: o celular não ficou na tomada nas 18h antes do relato (ônibus parado ou celular fora do carregador).'
             when 'bluetooth_ok' then 'Monitor Frota: Bluetooth ligado e leitor conectado nas 18h antes do relato; o problema não parece ser de conexão.'
             when 'sem_dados' then 'Monitor Frota: sem dados do celular nas 18h antes do relato.'
           end as observacao_monitor,
           case when o.categoria in ('carregamento','internet_chip') then 'alta'
                when o.categoria = 'contagem_passageiros' then
                  case when b.bt_causa = 'bluetooth_desligado' then 'baixa'
                       when o.problema ~* '(lent|devagar|demor)' then 'media' else 'alta' end
                when o.categoria = 'suporte' then 'media'
                when o.categoria = 'celular_defeito' then
                  case when o.problema ~* '(bateria inchad|inchad|tela trincad|tela quebrad|trincad|carca[cç]a)' then 'baixa'   -- nao se resolve rapido e nao para o carro
                       when o.problema ~* '(n[aã]o liga|desligad|apagad|sumi|morto|sem sinal de vida)' then 'alta' else 'media' end
                else 'baixa' end as prioridade,
           r.nome      as reporter_nome,        -- nome dado no app; vazio = use relatado_por (nome do WhatsApp)
           r.matricula as reporter_matricula,
           -- nome para mostrar: cadastrado no app > nome do WhatsApp (se for nome) > motorista da viagem do carro (API)
           coalesce(nullif(trim(r.nome),''), case when public.nome_valido(o.relatado_por) then o.relatado_por end,
                    o.motorista_viagem, o.relatado_por) as relator_exibir,
           case when nullif(trim(r.nome),'') is not null then 'cadastro' when public.nome_valido(o.relatado_por) then 'whatsapp'
                when o.motorista_viagem is not null then 'viagem' end as relator_fonte,
           -- horas de expediente do relato ate a baixa (aberta: ate agora)
           public.horas_uteis(coalesce(o.primeira_msg_em, o.criado_em),
                              case when o.status in ('resolvida','descartada') then coalesce(o.resolvido_em, o.atualizado_em)
                                   when o.status = 'historico' then null else now() end) as horas_uteis,
           -- entra na media de tempo? (relato do WhatsApp ao vivo, a partir de expediente.metricas_desde)
           (o.origem <> 'retroativo' and coalesce(o.primeira_msg_em, o.criado_em) >=
              coalesce((select e.metricas_desde from public.expediente e where e.id = 1), '-infinity')) as conta_no_tempo,
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
    -- desde quando: inicio do ultimo trecho continuo com o problema antes do relato
    left join lateral (
      select min(s.ts) as bt_desde from public.samples s
      where b.bt_causa in ('bluetooth_desligado','leitor_desconectado') and s.device_id = m.device_id
        and s.ts between coalesce(o.primeira_msg_em, o.criado_em) - interval '18 hours' and coalesce(o.primeira_msg_em, o.criado_em)
        and (case when b.bt_causa = 'bluetooth_desligado' then s.bt_on is false else s.bt_on and coalesce(s.bt_connected,'') = '' end)
        and s.ts > coalesce((select max(s2.ts) from public.samples s2 where s2.device_id = m.device_id
              and s2.ts between coalesce(o.primeira_msg_em, o.criado_em) - interval '18 hours' and coalesce(o.primeira_msg_em, o.criado_em)
              and (case when b.bt_causa = 'bluetooth_desligado' then s2.bt_on else coalesce(s2.bt_connected,'') <> '' end)), '-infinity')) bd on true
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

-- ---------------------------------------------------------------- AVISO NO GRUPO quando a ocorrencia e resolvida
-- O n8n (fluxo "Avisos de resolucao", a cada 2 min) pede avisos_pendentes() e responde EM CIMA da 1a mensagem do relato:
--   "✅ Antonio, a ocorrencia do carro 76 (contagem de passageiros) foi resolvida em 29/10 as 10:30.
--    Solucao: Bluetooth nao estava ligado."
-- So ocorrencias do WhatsApp ao vivo (nao o historico), relatadas e resolvidas a partir de whatsapp_avisos.desde,
-- que ninguem ja avisou no grupo. So no horario do expediente e no maximo max_por_hora (protege o numero de bloqueio).
-- COMECA DESLIGADO. Ligar:  update public.whatsapp_avisos set ligado = true;
create table if not exists public.whatsapp_avisos (
  id            smallint primary key default 1 check (id = 1),
  ligado        boolean not null default false,
  desde         timestamptz not null default '2026-10-29 00:00-03',
  max_por_hora  integer not null default 10 check (max_por_hora between 1 and 60)
);
insert into public.whatsapp_avisos (id) values (1) on conflict (id) do nothing;
alter table public.whatsapp_avisos enable row level security;
drop policy if exists "painel le avisos" on public.whatsapp_avisos;
create policy "painel le avisos" on public.whatsapp_avisos for select to anon, authenticated using (true);
drop policy if exists "painel liga avisos" on public.whatsapp_avisos;
create policy "painel liga avisos" on public.whatsapp_avisos for update to anon, authenticated using (true) with check (true);
revoke all on public.whatsapp_avisos from anon;
grant select on public.whatsapp_avisos to anon, authenticated;
-- o painel so pode ligar/desligar e mudar o limite; o texto e o link do aviso ficam so com o SQL Editor
grant update (ligado, max_por_hora) on public.whatsapp_avisos to anon, authenticated;

alter table public.ocorrencias
  add column if not exists aviso_enviado_em timestamptz,
  add column if not exists aviso_status     text,      -- enviado | erro | null = ainda nao
  add column if not exists aviso_erro       text;

create or replace function public.categoria_texto(p text) returns text
language sql immutable as $$
  select case p when 'carregamento' then 'carregamento' when 'abrir_viagem' then 'abrir viagem'
                when 'contagem_passageiros' then 'contagem de passageiros' when 'internet_chip' then 'internet / chip'
                when 'celular_defeito' then 'celular com defeito' when 'suporte' then 'suporte'
                when 'som_musica' then 'som / musica' else 'problema' end;
$$;

-- ---------------------------------------------------------------- LINK DE AVALIACAO no aviso (pesquisa de satisfacao)
-- Cada ocorrencia avisada ganha um codigo curto; o link abre avaliacao.html?t=CODIGO no GitHub Pages.
-- Os codigos ficam numa tabela que o painel NAO le (so as funcoes abaixo), para ninguem avaliar no lugar do motorista.
-- Sem link no aviso:  update public.whatsapp_avisos set avaliacao_url = null;
alter table public.whatsapp_avisos
  add column if not exists avaliacao_url   text default 'zael20.github.io/painel-mes-tfleet-bdv/a/',
  add column if not exists avaliacao_desde timestamptz default now();
-- link curto (05/11): pasta a/ e sem "https://" (o WhatsApp reconhece o link do mesmo jeito)
alter table public.whatsapp_avisos alter column avaliacao_url set default 'zael20.github.io/painel-mes-tfleet-bdv/a/';
update public.whatsapp_avisos set avaliacao_url = 'zael20.github.io/painel-mes-tfleet-bdv/a/'
 where avaliacao_url = 'https://zael20.github.io/painel-mes-tfleet-bdv/avaliacao.html';
create table if not exists public.avaliacao_links (
  ocorrencia_id bigint primary key references public.ocorrencias(id) on delete cascade,
  token         text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
  criado_em     timestamptz not null default now()
);
alter table public.avaliacao_links enable row level security;
revoke all on public.avaliacao_links from anon, authenticated;
create or replace function public.avaliacao_token_de(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare t text;
begin
  insert into avaliacao_links (ocorrencia_id) values (p_id) on conflict (ocorrencia_id) do nothing;
  select token into t from avaliacao_links where ocorrencia_id = p_id;
  return t;
end $$;
revoke all on function public.avaliacao_token_de(bigint) from public, anon, authenticated;
grant execute on function public.avaliacao_token_de(bigint) to service_role;

create or replace function public.avisos_pendentes(p_limite integer default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c whatsapp_avisos; e expediente; n integer; agora timestamp := now() at time zone 'America/Belem';
begin
  select * into c from whatsapp_avisos where id = 1;
  if not found or not c.ligado then return jsonb_build_object('avisos', '[]'::jsonb, 'motivo', 'desligado'); end if;
  select * into e from expediente where id = 1;
  if found and (agora::time not between e.inicio and e.fim
       or (extract(isodow from agora) = 6 and not e.conta_sabado) or (extract(isodow from agora) = 7 and not e.conta_domingo)
       or (not e.conta_feriado and exists (select 1 from feriados f where f.dia = agora::date))) then
    return jsonb_build_object('avisos', '[]'::jsonb, 'motivo', 'fora do expediente');
  end if;
  select count(*) into n from ocorrencias where aviso_status = 'enviado' and aviso_enviado_em > now() - interval '1 hour';
  if n >= c.max_por_hora then return jsonb_build_object('avisos', '[]'::jsonb, 'motivo', 'limite por hora'); end if;
  return jsonb_build_object('avisos', coalesce((select jsonb_agg(x) from (
    select o.id, m.grupo_jid, split_part(m.msg_id, '#', 1) as quoted_id, m.autor_jid,
           left(coalesce(nullif(m.texto,''), nullif(m.transcricao,''), '[' || m.tipo || ']'), 200) as quoted_texto,
           '✅ ' || coalesce(
              initcap(lower(split_part(public.nome_chave(coalesce(nullif(trim(r.nome),''),
                     case when public.nome_valido(o.relatado_por) then o.relatado_por end)), ' ', 1))) || ', a',
              'A') ||
           ' ocorrência do carro ' || coalesce(o.tag, '?') || ' (' || public.categoria_texto(o.categoria) || '), aberta em ' ||
           to_char(coalesce(o.primeira_msg_em, o.criado_em) at time zone 'America/Belem', 'DD/MM "às" HH24:MI') || ', foi resolvida em ' ||
           to_char(o.resolvido_em at time zone 'America/Belem', 'DD/MM "às" HH24:MI') || '.' ||
           -- solucao = o que foi escrito no CHECK BDV (o "o que foi feito" da vistoria, ou o texto do Marcar resolvida)
           coalesce(E'\nSolução: ' || nullif(trim(coalesce(nullif(trim(v.acao), ''),
                    regexp_replace(o.solucao, '^Vistoria de \d{2}/\d{2}: ', ''))), ''), '') ||
           coalesce(E'\n\nAvalie o atendimento: ' || lk.link, '') as texto,
           -- o n8n troca o link por um curto (is.gd); se o encurtador falhar, vai este mesmo
           lk.link
    from ocorrencias o
    cross join lateral (select w.* from whatsapp_msgs w where w.ocorrencia_id = o.id and w.grupo_jid like '%@g.us'
                         order by w.ts limit 1) m
    left join relatores r on r.phone = o.reporter_phone
    left join vistorias v on v.id = o.vistoria_id
    cross join lateral (select nullif(c.avaliacao_url, '') || case when c.avaliacao_url like '%.html' then '?t=' else '?' end ||
                               public.avaliacao_token_de(o.id) as link) lk
    where o.status = 'resolvida' and o.aviso_status is null and o.origem = 'whatsapp' and coalesce(o.resolvido_por,'') not in ('api','motorista')
      and coalesce(o.primeira_msg_em, o.criado_em) >= c.desde and o.resolvido_em >= c.desde
      and not exists (select 1 from whatsapp_msgs w where w.ocorrencia_id = o.id and w.acao_ia = 'resolve')  -- ja avisaram no grupo
    order by o.resolvido_em
    limit least(greatest(p_limite, 1), c.max_por_hora - n)) x), '[]'::jsonb), 'motivo', 'ok');
end $$;
revoke all on function public.avisos_pendentes(integer) from public, anon, authenticated;
grant execute on function public.avisos_pendentes(integer) to service_role;

-- o n8n marca depois de tentar (erro nao repete sozinho; para tentar de novo: update ocorrencias set aviso_status = null where id = N)
create or replace function public.aviso_marcar(p_id bigint, p_ok boolean, p_erro text default null) returns void
language sql security definer set search_path = public as $$
  update ocorrencias set aviso_enviado_em = now(), aviso_status = case when p_ok then 'enviado' else 'erro' end,
         aviso_erro = case when p_ok then null else left(p_erro, 500) end
   where id = p_id;
$$;
revoke all on function public.aviso_marcar(bigint, boolean, text) from public, anon, authenticated;
grant execute on function public.aviso_marcar(bigint, boolean, text) to service_role;

-- ================================================================ AVALIACAO DE SATISFACAO DOS MOTORISTAS
-- O aviso de resolvida leva o link avaliacao.html?t=CODIGO (secao "LINK DE AVALIACAO" acima).
-- Nota: 5 muito satisfeito, 4 satisfeito, 3 parcialmente, 2 pouco satisfeito, 1 insatisfeito.
-- Nota 3 ou menos pede o motivo (botoes) e/ou o que poderia ser melhor (texto).
-- So quem relatou avalia (numero do WhatsApp ou matricula), uma vez por ocorrencia.
-- O fluxo n8n "Agrupar avaliacoes" manda os textos ao Gemini, que junta os que dizem a mesma coisa num TEMA
-- (ex.: "suporte continuou quebrado" + "podia ter trocado o suporte" -> "Suporte nao foi resolvido de vez").
create table if not exists public.avaliacao_temas (
  id        bigserial primary key,
  titulo    text not null,      -- o problema, em poucas palavras
  melhoria  text,               -- o que fazer, ex.: "Verificar o suporte com mais frequencia na vistoria"
  criado_em timestamptz not null default now()
);
create unique index if not exists avaliacao_temas_titulo on public.avaliacao_temas (lower(titulo));

create table if not exists public.avaliacoes (
  id            bigserial primary key,
  ocorrencia_id bigint not null unique references public.ocorrencias(id) on delete cascade,
  nota          smallint not null check (nota between 1 and 5),
  motivos       text[] not null default '{}',
  observacao    text,
  tema_id       bigint references public.avaliacao_temas(id) on delete set null,
  tema_status   text,           -- null = falta agrupar | ok | sem_tema (texto sem sugestao) | erro
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists avaliacoes_tema on public.avaliacoes (tema_id);

alter table public.avaliacao_temas enable row level security;
alter table public.avaliacoes enable row level security;
drop policy if exists "painel le temas" on public.avaliacao_temas;
create policy "painel le temas" on public.avaliacao_temas for select to anon, authenticated using (true);
drop policy if exists "painel ajusta temas" on public.avaliacao_temas;
create policy "painel ajusta temas" on public.avaliacao_temas for update to anon, authenticated using (true) with check (true);
drop policy if exists "painel le avaliacoes" on public.avaliacoes;
create policy "painel le avaliacoes" on public.avaliacoes for select to anon, authenticated using (true);
revoke all on public.avaliacao_temas, public.avaliacoes from anon, authenticated;
grant select on public.avaliacao_temas, public.avaliacoes to anon, authenticated;
grant update (titulo, melhoria) on public.avaliacao_temas to anon, authenticated;   -- o CHECK BDV pode reescrever o tema

create or replace function public.avaliacao_motivo_texto(p text) returns text
language sql immutable as $$
  select case p when 'demorou' then 'Demorou para resolver' when 'voltou' then 'O problema voltou / não foi resolvido'
                when 'provisorio' then 'Conserto provisório ou mal feito' when 'sem_retorno' then 'Ninguém explicou o que foi feito'
                when 'atendimento' then 'Atendimento / forma de tratar' when 'outro' then 'Outro motivo' else p end;
$$;

-- QUEM PODE AVALIAR: so quem relatou aquele problema no grupo (quem abriu a ocorrencia ou quem relatou de novo
-- a mesma ocorrencia depois). A pessoa se identifica com o numero do WhatsApp (ou a matricula, se cadastrada no CHECK BDV).
-- Cada ocorrencia aceita UMA avaliacao; depois o link trava. 5 tentativas erradas bloqueiam o link.
alter table public.avaliacao_links
  add column if not exists tentativas       integer not null default 0,
  add column if not exists ultima_tentativa text,          -- so o final do numero digitado, para conferencia
  add column if not exists ultima_tentativa_em timestamptz;
alter table public.avaliacoes
  add column if not exists avaliador_phone text,
  add column if not exists avaliador_por   text,            -- 'telefone' | 'matricula'
  add column if not exists aparelho_id     text,            -- codigo guardado no navegador do celular que avaliou
  add column if not exists aparelho        jsonb,           -- modelo, Android, navegador, tela
  add column if not exists ip              text;

-- ANTIFRAUDE: toda tentativa na pagina fica registrada com o aparelho, o horario e o IP.
-- Se o mesmo aparelho aparece com numeros diferentes, o CHECK BDV avisa (ex.: alguem copiou o numero de outro).
-- Nao e prova absoluta (aba anonima ou limpar o navegador gera outro codigo), mas modelo + IP + horario ajudam a conferir.
create table if not exists public.avaliacao_eventos (
  id            bigserial primary key,
  ocorrencia_id bigint references public.ocorrencias(id) on delete cascade,
  ts            timestamptz not null default now(),
  tipo          text not null,      -- identificou | numero_errado | avaliou | bloqueado
  ident_final   text,               -- final do que foi digitado
  fone          text,               -- numero de quem relatou que bateu (null se errado)
  aparelho_id   text,
  aparelho      jsonb,
  ip            text
);
create index if not exists avaliacao_eventos_oc on public.avaliacao_eventos (ocorrencia_id, ts);
create index if not exists avaliacao_eventos_ap on public.avaliacao_eventos (aparelho_id);
alter table public.avaliacao_eventos enable row level security;
drop policy if exists "painel le eventos de avaliacao" on public.avaliacao_eventos;
create policy "painel le eventos de avaliacao" on public.avaliacao_eventos for select to anon, authenticated using (true);
revoke all on public.avaliacao_eventos from anon, authenticated;
grant select on public.avaliacao_eventos to anon, authenticated;

-- IP de quem chamou (o Supabase passa os cabecalhos da requisicao)
create or replace function public.req_ip() returns text
language sql stable as $$
  select nullif(coalesce(current_setting('request.headers', true)::json->>'cf-connecting-ip',
                         split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1)), '');
$$;
-- so guarda os campos conhecidos do aparelho, com tamanho limitado
create or replace function public.aparelho_limpo(a jsonb) returns jsonb
language sql immutable as $$
  select case when a is null or jsonb_typeof(a) <> 'object' then null else jsonb_strip_nulls(jsonb_build_object(
    'modelo', left(a->>'modelo', 60), 'marca', left(a->>'marca', 40), 'sistema', left(a->>'sistema', 40),
    'navegador', left(a->>'navegador', 60), 'tela', left(a->>'tela', 20), 'idioma', left(a->>'idioma', 20),
    'ua', left(a->>'ua', 300))) end;
$$;

-- telefones de quem relatou a ocorrencia (so digitos, com DDI)
create or replace function public.avaliacao_relatores(p_oc bigint) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct f) filter (where f is not null), '{}') from (
    select reporter_phone as f from ocorrencias where id = p_oc
    union all
    select public.normaliza_fone(w.autor_jid) from whatsapp_msgs w
     where w.ocorrencia_id = p_oc and w.acao_ia in ('nova', 'atualiza')) x;
$$;
revoke all on function public.avaliacao_relatores(bigint) from public, anon, authenticated;

-- mesmo numero? compara DDD + ultimos 8 digitos (o WhatsApp as vezes guarda o celular sem o 9)
create or replace function public.fone_bate(a text, b text) returns boolean
language sql immutable as $$
  with x as (select regexp_replace(regexp_replace(coalesce(a, ''), '\D', '', 'g'), '^55(?=\d{10,11}$)', '') as a,
                    regexp_replace(regexp_replace(coalesce(b, ''), '\D', '', 'g'), '^55(?=\d{10,11}$)', '') as b)
  select length(a) between 10 and 11 and length(b) between 10 and 11 and left(a, 2) = left(b, 2) and right(a, 8) = right(b, 8) from x;
$$;

-- confere a identificacao; conta tentativa errada. Devolve o telefone de quem relatou ou null.
drop function if exists public.avaliacao_conferir(text, text);
create or replace function public.avaliacao_conferir(p_token text, p_ident text, p_aparelho jsonb, out ok boolean, out erro text, out fone text, out por text)
language plpgsql security definer set search_path = public as $$
declare l avaliacao_links; rel text[]; dig text := regexp_replace(coalesce(p_ident, ''), '\D', '', 'g');
        ap jsonb := public.aparelho_limpo(p_aparelho); apid text := left(p_aparelho->>'id', 40);
begin
  ok := false;
  select * into l from avaliacao_links where token = p_token;
  if not found then erro := 'Link de avaliação inválido.'; return; end if;
  if exists (select 1 from avaliacoes where ocorrencia_id = l.ocorrencia_id) then erro := 'Essa ocorrência já foi avaliada. Obrigado!'; return; end if;
  if l.tentativas >= 5 then
    insert into avaliacao_eventos (ocorrencia_id, tipo, ident_final, aparelho_id, aparelho, ip) values (l.ocorrencia_id, 'bloqueado', right(dig, 4), apid, ap, public.req_ip());
    erro := 'Link bloqueado por tentativas erradas. Fale com a equipe do transporte.'; return;
  end if;
  if length(dig) < 4 then erro := 'Digite seu número de WhatsApp com DDD ou sua matrícula.'; return; end if;
  rel := public.avaliacao_relatores(l.ocorrencia_id);
  select r into fone from unnest(rel) r where public.fone_bate(r, dig) limit 1;
  if fone is not null then por := 'telefone';
  else
    select r.phone into fone from relatores r
     where r.phone = any (rel) and nullif(regexp_replace(coalesce(r.matricula, ''), '\D', '', 'g'), '') = dig limit 1;
    if fone is not null then por := 'matricula'; end if;
  end if;
  if fone is null then
    update avaliacao_links set tentativas = tentativas + 1, ultima_tentativa = '…' || right(dig, 4), ultima_tentativa_em = now()
     where ocorrencia_id = l.ocorrencia_id;
    insert into avaliacao_eventos (ocorrencia_id, tipo, ident_final, aparelho_id, aparelho, ip) values (l.ocorrencia_id, 'numero_errado', right(dig, 4), apid, ap, public.req_ip());
    erro := case when cardinality(rel) = 0 then 'Não achamos o número de quem relatou essa ocorrência, então ela não pode ser avaliada pelo link.'
                 else 'Esse número não é de quem relatou essa ocorrência no grupo. Só quem relatou pode avaliar.' end;
    return;
  end if;
  insert into avaliacao_eventos (ocorrencia_id, tipo, ident_final, fone, aparelho_id, aparelho, ip) values (l.ocorrencia_id, 'identificou', right(dig, 4), fone, apid, ap, public.req_ip());
  ok := true;
end $$;
revoke all on function public.avaliacao_conferir(text, text, jsonb) from public, anon, authenticated;

-- a pagina de avaliacao (publica) so ve a ocorrencia do proprio codigo, sem telefone
create or replace function public.avaliacao_ver(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tag', o.tag, 'categoria', public.categoria_texto(o.categoria), 'problema', o.problema, 'status', o.status,
    'aberta_em', coalesce(o.primeira_msg_em, o.criado_em), 'resolvido_em', o.resolvido_em, 'resolvido_por', o.resolvido_por,
    'solucao', coalesce(nullif(trim(v.acao), ''), regexp_replace(o.solucao, '^Vistoria de \d{2}/\d{2}: ', '')),
    -- o que a vistoria viu (sem observacao nem pendencias internas, que nao vao ao motorista)
    'vistoria', case when v.id is not null then jsonb_build_object('ts', v.ts, 'data', v.data_vistoria, 'status', v.status, 'local', v.local,
        'itens', jsonb_build_object('Aplicativo BDV', v.item_app, 'Chip / internet', v.item_chip, 'Cabo / carregador', v.item_cabo,
                                    'Leitor', v.item_leitor, 'Suporte', v.item_suporte, 'Celular', v.item_celular),
        'feito', nullif(trim(v.acao), ''), 'fotos', to_jsonb(v.fotos)) end,
    'ja_avaliada', exists (select 1 from avaliacoes a where a.ocorrencia_id = o.id),
    'bloqueado', l.tentativas >= 5)
  from avaliacao_links l
  join ocorrencias o on o.id = l.ocorrencia_id
  left join vistorias v on v.id = o.vistoria_id
  where l.token = p_token and o.status <> 'descartada';
$$;
revoke all on function public.avaliacao_ver(text) from public;
grant execute on function public.avaliacao_ver(text) to anon, authenticated, service_role;

-- 1o passo da pagina: confere quem esta avaliando antes de mostrar as notas
drop function if exists public.avaliacao_identificar(text, text);
create or replace function public.avaliacao_identificar(p_token text, p_ident text, p_aparelho jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c record; nome text;
begin
  select * into c from public.avaliacao_conferir(p_token, p_ident, p_aparelho);
  if not c.ok then return jsonb_build_object('ok', false, 'erro', c.erro); end if;
  select coalesce(nullif(trim(r.nome), ''),
           (select w.autor_nome from whatsapp_msgs w join avaliacao_links l on l.ocorrencia_id = w.ocorrencia_id
             where l.token = p_token and public.normaliza_fone(w.autor_jid) = c.fone and public.nome_valido(w.autor_nome) limit 1))
    into nome from (select 1) z left join relatores r on r.phone = c.fone;
  nome := nullif(initcap(lower(split_part(public.nome_chave(nome), ' ', 1))), '');
  return jsonb_build_object('ok', true, 'nome', nome);
end $$;
revoke all on function public.avaliacao_identificar(text, text, jsonb) from public;
grant execute on function public.avaliacao_identificar(text, text, jsonb) to anon, authenticated, service_role;

-- grava a avaliacao (uma so por ocorrencia, de quem relatou)
drop function if exists public.avaliacao_responder(text, integer, text[], text);
drop function if exists public.avaliacao_responder(text, text, integer, text[], text);
create or replace function public.avaliacao_responder(p_token text, p_ident text, p_nota integer, p_motivos text[] default '{}', p_observacao text default null,
                                                      p_aparelho jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c record; oc bigint; mot text[]; obs text := nullif(left(trim(coalesce(p_observacao, '')), 1000), '');
begin
  if p_nota is null or p_nota not between 1 and 5 then return jsonb_build_object('ok', false, 'erro', 'Escolha uma das 5 opções.'); end if;
  select coalesce(array_agg(distinct m), '{}') into mot from unnest(coalesce(p_motivos, '{}')) m
   where m in ('demorou','voltou','provisorio','sem_retorno','atendimento','outro');
  if p_nota >= 4 then mot := '{}'; obs := null; end if;   -- nota boa: sem motivos
  if p_nota <= 3 and cardinality(mot) = 0 and obs is null then return jsonb_build_object('ok', false, 'erro', 'Conte o que poderia ter sido melhor.'); end if;
  select * into c from public.avaliacao_conferir(p_token, p_ident, p_aparelho);
  if not c.ok then return jsonb_build_object('ok', false, 'erro', c.erro); end if;
  select ocorrencia_id into oc from avaliacao_links where token = p_token;
  insert into avaliacoes (ocorrencia_id, nota, motivos, observacao, avaliador_phone, avaliador_por, aparelho_id, aparelho, ip)
  values (oc, p_nota, mot, obs, c.fone, c.por, left(p_aparelho->>'id', 40), public.aparelho_limpo(p_aparelho), public.req_ip())
  on conflict (ocorrencia_id) do nothing;
  if not found then return jsonb_build_object('ok', false, 'erro', 'Essa ocorrência já foi avaliada. Obrigado!'); end if;
  insert into avaliacao_eventos (ocorrencia_id, tipo, ident_final, fone, aparelho_id, aparelho, ip)
  values (oc, 'avaliou', right(regexp_replace(coalesce(p_ident, ''), '\D', '', 'g'), 4), c.fone, left(p_aparelho->>'id', 40), public.aparelho_limpo(p_aparelho), public.req_ip());
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.avaliacao_responder(text, text, integer, text[], text, jsonb) from public;
grant execute on function public.avaliacao_responder(text, text, integer, text[], text, jsonb) to anon, authenticated, service_role;

-- para o CHECK BDV ver tentativas de outro numero (sem o codigo do link)
create or replace view public.v_avaliacao_tentativas as
  select ocorrencia_id, tentativas, ultima_tentativa, ultima_tentativa_em from public.avaliacao_links where tentativas > 0;
grant select on public.v_avaliacao_tentativas to anon, authenticated;

-- n8n: textos que ainda nao tem tema + temas que ja existem (com quantas avaliacoes cada um tem)
create or replace function public.avaliacoes_para_agrupar(p_limite integer default 25) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'itens', coalesce((select jsonb_agg(x) from (
       select a.id, a.nota, a.observacao, (select array_agg(public.avaliacao_motivo_texto(m)) from unnest(a.motivos) m) as motivos,
              public.categoria_texto(o.categoria) as categoria, o.problema, o.solucao
         from avaliacoes a join ocorrencias o on o.id = a.ocorrencia_id
        where a.tema_status is null and length(coalesce(a.observacao, '')) >= 3
        order by a.atualizado_em limit greatest(least(p_limite, 50), 1)) x), '[]'::jsonb),
    'temas', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'titulo', t.titulo, 'melhoria', t.melhoria,
                 'qtd', (select count(*) from avaliacoes a where a.tema_id = t.id)) order by t.id) from avaliacao_temas t), '[]'::jsonb));
$$;
revoke all on function public.avaliacoes_para_agrupar(integer) from public, anon, authenticated;
grant execute on function public.avaliacoes_para_agrupar(integer) to service_role;

-- n8n: grava a resposta do Gemini. p = {"itens":[{"id":1,"tema_id":3}, {"id":2,"novo_titulo":"...","nova_melhoria":"..."},
-- {"id":4,"sem_tema":true}]}. Tema novo com o mesmo titulo de um que ja existe reaproveita o existente.
create or replace function public.avaliacoes_aplicar_temas(p jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare it jsonb; tid bigint; n integer := 0;
begin
  for it in select * from jsonb_array_elements(coalesce(p->'itens', '[]'::jsonb)) loop
    tid := null;
    if coalesce((it->>'sem_tema')::boolean, false) then
      update avaliacoes set tema_id = null, tema_status = 'sem_tema' where id = (it->>'id')::bigint and tema_status is null;
      n := n + 1; continue;
    end if;
    if nullif(it->>'tema_id', '') is not null and (it->>'tema_id') ~ '^\d+$' then
      select id into tid from avaliacao_temas where id = (it->>'tema_id')::bigint;
    end if;
    if tid is null and nullif(trim(it->>'novo_titulo'), '') is not null then
      insert into avaliacao_temas (titulo, melhoria) values (left(trim(it->>'novo_titulo'), 120), left(nullif(trim(it->>'nova_melhoria'), ''), 300))
      on conflict ((lower(titulo))) do nothing returning id into tid;
      if tid is null then select id into tid from avaliacao_temas where lower(titulo) = lower(left(trim(it->>'novo_titulo'), 120)); end if;
    end if;
    update avaliacoes set tema_id = tid, tema_status = case when tid is null then 'erro' else 'ok' end
     where id = (it->>'id')::bigint and tema_status is null;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.avaliacoes_aplicar_temas(jsonb) from public, anon, authenticated;
grant execute on function public.avaliacoes_aplicar_temas(jsonb) to service_role;
-- para mandar tudo de novo ao Gemini (ex.: depois de mudar o prompt):
--   update public.avaliacoes set tema_id = null, tema_status = null; delete from public.avaliacao_temas;

-- o que o CHECK BDV le: uma linha por avaliacao, com o carro, a ocorrencia e o tema
drop view if exists public.v_avaliacoes;
create view public.v_avaliacoes with (security_invoker = on) as
  select a.id, a.ocorrencia_id, a.nota, a.motivos, a.observacao, a.tema_id, a.tema_status, a.criado_em, a.atualizado_em,
         t.titulo as tema_titulo, t.melhoria as tema_melhoria,
         o.tag, o.categoria, o.problema, o.solucao, o.resolvido_em, o.resolvido_por, o.reporter_phone, o.relatado_por,
         a.avaliador_phone, a.avaliador_por, ra.nome as avaliador_nome, ra.matricula as avaliador_matricula,
         a.aparelho_id, a.aparelho, a.ip,
         -- ALERTA: outros numeros que ja se identificaram neste mesmo aparelho (em qualquer avaliacao)
         (select array_agg(distinct e.fone) from public.avaliacao_eventos e
           where a.aparelho_id is not null and e.aparelho_id = a.aparelho_id and e.fone is not null
             and not public.fone_bate(e.fone, a.avaliador_phone)) as aparelho_outros_numeros
    from avaliacoes a
    join ocorrencias o on o.id = a.ocorrencia_id
    left join avaliacao_temas t on t.id = a.tema_id
    left join relatores ra on ra.phone = a.avaliador_phone;
grant select on public.v_avaliacoes to anon, authenticated;


-- ================================================================ PERGUNTAR O NUMERO DO CARRO (06/11)
-- Relato sem numero (status aguardando_carro): 3 min depois o fluxo "Avisos de resolucao" responde EM CIMA da mensagem:
--   "🔎 Antonio, não identifiquei o número do carro nesta mensagem. Responda esta mensagem só com o número..."
-- Se o motorista responder sem numero legivel (ex.: outra foto), pergunta mais 1 vez. A resposta "Carro 84" citando a
-- pergunta abre o chamado no carro certo. Limite por hora: o mesmo max_por_hora dos avisos (somando os dois).
-- COMECA DESLIGADO. Ligar:  update public.whatsapp_avisos set perguntar_carro = true;
alter table public.whatsapp_avisos
  add column if not exists perguntar_carro boolean not null default false,
  add column if not exists perguntar_desde timestamptz not null default now();
grant update (ligado, max_por_hora, perguntar_carro) on public.whatsapp_avisos to anon, authenticated;
alter table public.ocorrencias
  add column if not exists pergunta_status text,                    -- enviada | erro | null = ainda nao perguntou
  add column if not exists pergunta_em     timestamptz,
  add column if not exists pergunta_qtd    integer not null default 0,
  add column if not exists pergunta_msg_id text,                    -- id da pergunta no WhatsApp (resposta citando ela)
  add column if not exists pergunta_erro   text;
create index if not exists ocorrencias_pergunta_msg on public.ocorrencias (pergunta_msg_id) where pergunta_msg_id is not null;

create or replace function public.perguntas_carro_pendentes(p_limite integer default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c whatsapp_avisos; n integer;
begin
  select * into c from whatsapp_avisos where id = 1;
  if not found or not c.perguntar_carro then return jsonb_build_object('perguntas', '[]'::jsonb, 'motivo', 'desligado'); end if;
  select count(*) into n from ocorrencias
   where (aviso_status = 'enviado' and aviso_enviado_em > now() - interval '1 hour')
      or (pergunta_status = 'enviada' and pergunta_em > now() - interval '1 hour');
  if n >= c.max_por_hora then return jsonb_build_object('perguntas', '[]'::jsonb, 'motivo', 'limite por hora'); end if;
  return jsonb_build_object('perguntas', coalesce((select jsonb_agg(x) from (
    select o.id, m.grupo_jid, split_part(m.msg_id, '#', 1) as quoted_id, m.autor_jid,
           left(coalesce(nullif(m.texto,''), nullif(m.transcricao,''), '[' || m.tipo || ']'), 200) as quoted_texto,
           '🔎 ' || coalesce(
              initcap(lower(split_part(public.nome_chave(coalesce(nullif(trim(r.nome),''),
                     case when public.nome_valido(o.relatado_por) then o.relatado_por end)), ' ', 1))) || ', n', 'N') ||
           case when o.pergunta_qtd = 0
                then 'ão identifiquei o número do carro nesta mensagem (' || public.categoria_texto(o.categoria) || ').'
                else 'ão consegui ler o número do carro de novo.' end ||
           E'\nResponda esta mensagem só com o número, por exemplo: *Carro 84*' as texto
    from ocorrencias o
    cross join lateral (select w.* from whatsapp_msgs w where w.ocorrencia_id = o.id and w.grupo_jid like '%@g.us'
                         order by case when o.pergunta_qtd = 0 then w.ts end, w.ts desc limit 1) m
    left join relatores r on r.phone = o.reporter_phone
    where o.status = 'aguardando_carro' and o.tag is null and o.origem = 'whatsapp'
      and coalesce(o.pergunta_status, '') <> 'erro'
      and coalesce(o.procedimento_status, '') not in ('pendente','enviado')   -- o passo a passo ja pede o numero
      and coalesce(o.primeira_msg_em, o.criado_em) >= c.perguntar_desde
      and coalesce(o.primeira_msg_em, o.criado_em) > now() - interval '12 hours'
      and coalesce(o.primeira_msg_em, o.criado_em) < now() - interval '3 minutes'
      -- o motorista ainda esta mandando mensagens: espera 2 min de silencio
      and not exists (select 1 from whatsapp_msgs w where w.ocorrencia_id = o.id and w.ts > now() - interval '2 minutes')
      and (o.pergunta_qtd = 0
           or (o.pergunta_qtd = 1 and exists (select 1 from whatsapp_msgs w where w.ocorrencia_id = o.id and w.ts > o.pergunta_em)))
    order by coalesce(o.primeira_msg_em, o.criado_em)
    limit least(greatest(p_limite, 1), c.max_por_hora - n)) x), '[]'::jsonb), 'motivo', 'ok');
end $$;
revoke all on function public.perguntas_carro_pendentes(integer) from public, anon, authenticated;
grant execute on function public.perguntas_carro_pendentes(integer) to service_role;

-- o n8n marca depois de perguntar (erro nao repete; para tentar de novo: update ocorrencias set pergunta_status = null where id = N)
create or replace function public.pergunta_marcar(p_id bigint, p_ok boolean, p_erro text default null, p_msg_id text default null) returns void
language sql security definer set search_path = public as $$
  update ocorrencias set pergunta_em = now(), pergunta_status = case when p_ok then 'enviada' else 'erro' end,
         pergunta_qtd = pergunta_qtd + case when p_ok then 1 else 0 end,
         pergunta_msg_id = case when p_ok then coalesce(nullif(p_msg_id, ''), pergunta_msg_id) else pergunta_msg_id end,
         pergunta_erro = case when p_ok then null else left(p_erro, 500) end
   where id = p_id;
$$;
revoke all on function public.pergunta_marcar(bigint, boolean, text, text) from public, anon, authenticated;
grant execute on function public.pergunta_marcar(bigint, boolean, text, text) to service_role;

-- passada unica: relatos do WhatsApp que ja estao abertos SEM carro passam a "aguardando o numero do carro"
update public.ocorrencias set status = 'aguardando_carro'
 where status = 'aberta' and tag is null and origem = 'whatsapp';
select count(*) filter (where status = 'aguardando_carro') as aguardando_numero_do_carro,
       count(*) filter (where status in ('aberta','em_andamento')) as abertas
  from public.ocorrencias;

-- ================================================================ PASSO A PASSO "NAO REGISTRA PASSAGEIRO" (11/11)
-- Relato de "nao registra / nao le passageiro": em vez de abrir o chamado, o fluxo "Avisos de resolucao" responde EM CIMA
-- do relato com o video (ou so o texto, se nao houver video) do passo a passo e pergunta se deu certo:
--   "Deu certo" -> resolvida (resolvido_por = 'motorista').  "Nao deu" ou nada em procedimento_espera_min -> aberta.
-- Se depois a API mostrar o carro registrando de novo, fecha sozinha (resolver_contagem_pela_api).
-- COMECA DESLIGADO. Ligar:  update public.whatsapp_avisos set procedimento_ligado = true;
-- Video:  update public.whatsapp_avisos set procedimento_video_url = 'https://.../passo-a-passo.mp4';  (link publico, mp4 ate 16 MB)
alter table public.whatsapp_avisos
  add column if not exists procedimento_ligado     boolean not null default false,
  add column if not exists procedimento_video_url  text,
  add column if not exists procedimento_espera_min integer not null default 30 check (procedimento_espera_min between 5 and 720),
  add column if not exists procedimento_desde      timestamptz not null default now();
grant update (ligado, max_por_hora, perguntar_carro, procedimento_ligado) on public.whatsapp_avisos to anon, authenticated;
create index if not exists ocorrencias_procedimento_msg on public.ocorrencias (procedimento_msg_id) where procedimento_msg_id is not null;

-- o relato e do tipo que o passo a passo resolve?
create or replace function public.procedimento_aplica(p_cat text, p_problema text) returns boolean
language sql immutable as $$
  select coalesce(p_problema, '') !~* '(bateria inchad|inchad|tela trincad|tela quebrad|trincad|carca[cç]a|lent|devagar|demor)'
     and (p_cat = 'contagem_passageiros'
          or (p_cat in ('abrir_viagem','celular_defeito','outro') and coalesce(p_problema, '') ~* '(registr|passageir|crach|leitor|cart[aã]o)'));
$$;

-- resposta do motorista: 'sim' (deu certo), 'nao' (nao deu) ou null (nao e resposta). Qualquer "nao" na frase = nao.
create or replace function public.resposta_procedimento(t text) returns text
language sql immutable as $$
  select case
    when t is null or length(trim(t)) = 0 or length(t) > 120 then null
    -- qualquer negativa: "nao", "N", "num/nem funcionou", "deu errado", "nao prestou", "continua", "falhou", "sem sucesso"...
    when t ~* '(^|[^[:alpha:]])(n[aã]o|nao|n|num|nem|nop|nops|negativo|continua|continuou|nada|nunca|falhou|falha|errado|erro|ruim|piorou|sem sucesso|sem resultado)([^[:alpha:]]|$)'
      or t ~* 'mesm[oa] (coisa|problema|jeito)|ainda n|n[aã]o presta|parado|travad|zerad|❌|👎' then 'nao'
    when t ~* '(^|[^[:alpha:]])(sim|s|deu|positivo|funcionou|resolveu|resolvido|voltou|subiu|subindo|lendo|registrando|registrou|normalizou|certinho|beleza|blz|show)([^[:alpha:]]|$)'
      then 'sim'
  end;
$$;

create or replace function public.procedimentos_pendentes(p_limite integer default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c whatsapp_avisos; n integer; v_tem boolean;
begin
  select * into c from whatsapp_avisos where id = 1;
  v_tem := found;
  -- sem resposta no prazo (ou o envio falhou): abre o chamado
  update ocorrencias set procedimento_status = case when procedimento_status = 'enviado' then 'sem_resposta' else procedimento_status end,
         status = case when status = 'aguardando_teste' then 'aberta' else status end
   where status in ('aguardando_teste','aguardando_carro')
     and (procedimento_status = 'erro'
          or (procedimento_status = 'enviado' and procedimento_em < now() - make_interval(mins => coalesce(c.procedimento_espera_min, 30)))
          -- desligado (ou ficou pendente por mais de 2 h): nao segura o chamado
          or (procedimento_status = 'pendente' and (not coalesce(c.procedimento_ligado, false)
                                                    or coalesce(procedimento_em, primeira_msg_em, criado_em) < now() - interval '2 hours')));
  update ocorrencias set procedimento_status = null where procedimento_status = 'pendente' and status = 'aberta';
  if not v_tem or not coalesce(c.procedimento_ligado, false) then
    return jsonb_build_object('procedimentos', '[]'::jsonb, 'motivo', 'desligado');
  end if;
  select count(*) into n from ocorrencias
   where (aviso_status = 'enviado' and aviso_enviado_em > now() - interval '1 hour')
      or (pergunta_status = 'enviada' and pergunta_em > now() - interval '1 hour')
      or (procedimento_status <> 'pendente' and procedimento_msg_id is not null and procedimento_em > now() - interval '1 hour');
  if n >= c.max_por_hora then return jsonb_build_object('procedimentos', '[]'::jsonb, 'motivo', 'limite por hora'); end if;
  -- 1a etapa: se o Monitor Frota ja mostra a causa (Bluetooth desligado / outro aparelho pareado), manda so isso, sem video
  update ocorrencias o set procedimento_dica = d.dica, procedimento_etapa = case when d.dica is not null then 'monitor' else 'video' end
    from (select x.id, public.monitor_dica(x.id) as dica from ocorrencias x
           where x.procedimento_status = 'pendente' and x.procedimento_etapa is null
             and x.status in ('aguardando_teste','aguardando_carro') and x.origem = 'whatsapp') d
   where o.id = d.id;
  return jsonb_build_object('procedimentos', coalesce((select jsonb_agg(x) from (
    select o.id, m.grupo_jid, split_part(m.msg_id, '#', 1) as quoted_id, m.autor_jid,
           left(coalesce(nullif(m.texto,''), nullif(m.transcricao,''), '[' || m.tipo || ']'), 200) as quoted_texto,
           case when o.procedimento_etapa = 'video' then nullif(trim(c.procedimento_video_url), '') end as video_url,
           case when o.procedimento_etapa = 'monitor' then
             '🔎 ' || coalesce(
                initcap(lower(split_part(public.nome_chave(coalesce(nullif(trim(r.nome),''),
                       case when public.nome_valido(o.relatado_por) then o.relatado_por end)), ' ', 1))) || ', o', 'O') ||
             ' Monitor do celular do carro ' || o.tag || E' mostra:
' || o.procedimento_dica ||
             E'

Depois passe o crachá de novo e responda esta mensagem: *DEU CERTO* ou *NÃO DEU*.'
           else
           (case when o.procedimento_etapa = 'video' and o.procedimento_dica is not null then 'Vamos tentar outra coisa. ' else '' end) ||
           '🔧 ' || coalesce(
              initcap(lower(split_part(public.nome_chave(coalesce(nullif(trim(r.nome),''),
                     case when public.nome_valido(o.relatado_por) then o.relatado_por end)), ' ', 1))) || ', t', 'T') ||
           'ente este passo a passo' || case when nullif(trim(c.procedimento_video_url), '') is not null then ' do vídeo' else '' end || E':\n' ||
           E'1) Com a viagem aberta, feche o app BDV (deslize para cima).\n' ||
           E'2) Abra o app de novo e entre com login, senha e matrícula.\n' ||
           E'3) Peça para os passageiros passarem o crachá de novo.\n' ||
           E'4) Se ainda não subir, confira se o Bluetooth do celular está ligado.\n\n' ||
           'Depois responda esta mensagem: *DEU CERTO* ou *NÃO DEU*' ||
           case when o.tag is null then E'\nE mande também o número do carro (ex.: *Carro 84*).' else '.' end
           end as texto
    from ocorrencias o
    cross join lateral (select w.* from whatsapp_msgs w where w.ocorrencia_id = o.id and w.grupo_jid like '%@g.us'
                         order by w.ts limit 1) m
    left join relatores r on r.phone = o.reporter_phone
    where o.procedimento_status = 'pendente' and o.status in ('aguardando_teste','aguardando_carro') and o.origem = 'whatsapp'
      and coalesce(o.primeira_msg_em, o.criado_em) >= c.procedimento_desde
      and coalesce(o.primeira_msg_em, o.criado_em) < now() - interval '1 minute'
      and not exists (select 1 from whatsapp_msgs w where w.ocorrencia_id = o.id and w.ts > now() - interval '1 minute')
      and o.procedimento_etapa is not null
    order by coalesce(o.primeira_msg_em, o.criado_em)
    limit least(greatest(p_limite, 1), c.max_por_hora - n)) x), '[]'::jsonb), 'motivo', 'ok');
end $$;
revoke all on function public.procedimentos_pendentes(integer) from public, anon, authenticated;
grant execute on function public.procedimentos_pendentes(integer) to service_role;

-- O que o Monitor Frota sabe do Bluetooth do celular do carro (18 h antes do relato ate agora). Null = nada a dizer.
--   * Bluetooth desligado (3+ minutos seguidos): "desligado desde DD/MM as HH:MM" (ou "foi desligado ... e religado")
--   * Mais de 1 aparelho pareado (o certo e so o leitor): nome do(s) aparelho(s) que nao parece(m) leitor
create or replace function public.monitor_dica(p_oc bigint) returns text
language plpgsql stable security definer set search_path = public as $$
declare o record; v_dev text; v_ini timestamptz; s record; v_off_ini timestamptz; v_off_fim timestamptz; v_n int;
        v_extra text; dicas text[] := '{}';
begin
  if to_regclass('public.samples') is null or to_regclass('public.v_last_sample') is null then return null; end if;
  select * into o from ocorrencias where id = p_oc;
  if not found or o.tag is null then return null; end if;
  v_ini := coalesce(o.primeira_msg_em, o.criado_em) - interval '18 hours';
  execute 'select device_id from public.v_last_sample where public.normaliza_tag(device_name) = $1 order by ts desc limit 1'
     into v_dev using o.tag;
  if v_dev is null then return null; end if;
  execute 'select ts, bt_on, bt_bonded, bt_bonded_count from public.samples where device_id = $1 order by ts desc limit 1'
     into s using v_dev;
  if s.ts is null or s.ts < v_ini then return null; end if;
  -- ultimo trecho com Bluetooth desligado
  execute 'select max(ts) from public.samples where device_id = $1 and ts >= $2 and bt_on is false' into v_off_fim using v_dev, v_ini;
  if v_off_fim is not null then
    execute 'select coalesce(min(ts), $3) from public.samples where device_id = $1 and ts >= $2 and ts <= $3 and bt_on is false
               and ts > coalesce((select max(ts) from public.samples where device_id = $1 and ts >= $2 and ts < $3 and bt_on), ''-infinity'')'
       into v_off_ini using v_dev, v_ini, v_off_fim;
    execute 'select count(*) from public.samples where device_id = $1 and ts between $2 and $3 and bt_on is false'
       into v_n using v_dev, v_off_ini, v_off_fim;
    if v_n >= 3 then
      dicas := dicas || case when s.bt_on is false
        then '• O Bluetooth está DESLIGADO desde ' || to_char(v_off_ini at time zone 'America/Belem', 'DD/MM "às" HH24:MI') ||
             '. Ligue o Bluetooth (puxe a tela de cima para baixo e toque no ícone).'
        else '• O Bluetooth foi desligado em ' || to_char(v_off_ini at time zone 'America/Belem', 'DD/MM "às" HH24:MI') ||
             ' e ficou assim até ' || to_char(v_off_fim at time zone 'America/Belem', 'HH24:MI') ||
             '. Confira se ele está ligado agora.' end;
    end if;
  end if;
  -- outro aparelho pareado alem do leitor
  if coalesce(s.bt_bonded_count, 0) > 1 and coalesce(trim(s.bt_bonded), '') <> '' then
    select string_agg('"' || trim(x) || '"', ', ') into v_extra
      from unnest(string_to_array(s.bt_bonded, ',')) x
     where trim(x) <> '' and trim(x) !~* '(SGBT|RFID|leitor|reader|UHF|NFC|R20)';
    dicas := dicas || ('• Tem outro aparelho pareado no Bluetooth além do leitor: ' ||
             coalesce(v_extra, '"' || s.bt_bonded || '"') ||
             '. Em Configurações > Bluetooth, toque na engrenagem ao lado dele, escolha Desemparelhar e tente de novo.');
  end if;
  return nullif(array_to_string(dicas, E'\n'), '');
end $$;
revoke all on function public.monitor_dica(bigint) from public, anon, authenticated;

-- o n8n marca depois de enviar; erro = abre o chamado na proxima rodada
create or replace function public.procedimento_marcar(p_id bigint, p_ok boolean, p_erro text default null, p_msg_id text default null) returns void
language sql security definer set search_path = public as $$
  update ocorrencias set procedimento_em = now(), procedimento_status = case when p_ok then 'enviado' else 'erro' end,
         procedimento_msg_id = case when p_ok then nullif(p_msg_id, '') else procedimento_msg_id end,
         procedimento_erro = case when p_ok then null else left(p_erro, 500) end
   where id = p_id and procedimento_status = 'pendente';
$$;
revoke all on function public.procedimento_marcar(bigint, boolean, text, text) from public, anon, authenticated;
grant execute on function public.procedimento_marcar(bigint, boolean, text, text) to service_role;

-- passada unica: o que a API ja mostra que voltou a registrar (inclui as categorias novas de 11/11)
select public.resolver_contagem_pela_api() as fechadas_agora_pela_api;
