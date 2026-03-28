-- ─── ADICIONAR COLUNAS DE PARCELAS NO CARTAO ────────────────────────────────
alter table cartao_lancamentos
  add column if not exists total_parcelas integer default 1,
  add column if not exists parcela_atual integer default 1,
  add column if not exists grupo_parcela uuid default null,
  add column if not exists recorrente boolean default false;

-- ─── ADICIONAR COLUNAS DE RECORRENCIA NOS BOLETOS ────────────────────────────
alter table boletos
  add column if not exists recorrente boolean default false,
  add column if not exists grupo_recorrencia uuid default null;

-- ─── ADICIONAR CAMPO DE ARQUIVADO NOS MESES ──────────────────────────────────
alter table meses
  add column if not exists arquivado boolean default false;

-- ─── FUNCAO: GERAR 12 MESES AUTOMATICAMENTE PARA UM USUARIO ─────────────────
create or replace function gerar_meses_usuario(p_usuario_id uuid)
returns void as $$
declare
  v_mes date;
  v_ref text;
  v_inicio date := date_trunc('month', current_date);
begin
  for i in 0..11 loop
    v_mes := v_inicio + (i || ' months')::interval;
    v_ref := to_char(v_mes, 'YYYY-MM');
    insert into meses (usuario_id, mes_referencia, saldo_inicial, vencimento_cartao, saldo_minimo, meta_economia, arquivado)
    values (p_usuario_id, v_ref, 0, 10, 500, 1000, false)
    on conflict do nothing;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

-- ─── FUNCAO: ARQUIVAR MESES PASSADOS AUTOMATICAMENTE ─────────────────────────
create or replace function arquivar_meses_passados()
returns void as $$
begin
  update meses
  set arquivado = true
  where mes_referencia < to_char(date_trunc('month', current_date), 'YYYY-MM')
    and arquivado = false;
end;
$$ language plpgsql security definer set search_path = public;

-- ─── FUNCAO: PROPAGAR PARCELAS NOS MESES SEGUINTES ───────────────────────────
create or replace function propagar_parcelas(
  p_lancamento_id uuid,
  p_usuario_id uuid,
  p_mes_id uuid,
  p_descricao text,
  p_categoria text,
  p_valor_total numeric,
  p_valor_usuario numeric,
  p_total_parcelas integer,
  p_grupo_parcela uuid,
  p_divisoes jsonb
)
returns void as $$
declare
  v_mes_ref text;
  v_proximo_mes text;
  v_proximo_mes_id uuid;
  v_novo_lancamento_id uuid;
  v_divisao jsonb;
begin
  -- Buscar referencia do mes atual
  select mes_referencia into v_mes_ref from meses where id = p_mes_id;

  -- Para cada parcela restante
  for i in 2..p_total_parcelas loop
    -- Calcular o mes seguinte
    v_proximo_mes := to_char(
      (to_date(v_mes_ref, 'YYYY-MM') + ((i-1) || ' months')::interval),
      'YYYY-MM'
    );

    -- Buscar ou criar o mes seguinte
    select id into v_proximo_mes_id
    from meses
    where usuario_id = p_usuario_id and mes_referencia = v_proximo_mes;

    if v_proximo_mes_id is null then
      insert into meses (usuario_id, mes_referencia, saldo_inicial, vencimento_cartao, saldo_minimo, meta_economia, arquivado)
      values (p_usuario_id, v_proximo_mes, 0, 10, 500, 1000, false)
      returning id into v_proximo_mes_id;
    end if;

    -- Inserir lancamento da parcela no mes seguinte
    insert into cartao_lancamentos (
      mes_id, usuario_id, data, parcela, descricao, categoria,
      valor, valor_usuario, total_parcelas, parcela_atual, grupo_parcela, recorrente
    )
    values (
      v_proximo_mes_id, p_usuario_id,
      '01/' || to_char(to_date(v_proximo_mes, 'YYYY-MM'), 'MM/YYYY'),
      i || '/' || p_total_parcelas,
      p_descricao, p_categoria,
      p_valor_total, p_valor_usuario,
      p_total_parcelas, i, p_grupo_parcela, false
    )
    returning id into v_novo_lancamento_id;

    -- Propagar divisoes
    if p_divisoes is not null then
      insert into cartao_divisoes (lancamento_id, integrante_id, usuario_id, valor)
      select v_novo_lancamento_id, (d->>'integrante_id')::uuid, p_usuario_id, (d->>'valor')::numeric
      from jsonb_array_elements(p_divisoes) d;
    end if;

  end loop;
end;
$$ language plpgsql security definer set search_path = public;

-- ─── FUNCAO: PROPAGAR BOLETO RECORRENTE ──────────────────────────────────────
create or replace function propagar_boleto_recorrente(
  p_usuario_id uuid,
  p_mes_id uuid,
  p_descricao text,
  p_valor numeric,
  p_vencimento_dia integer,
  p_meses integer,
  p_grupo_recorrencia uuid
)
returns void as $$
declare
  v_mes_ref text;
  v_proximo_mes text;
  v_proximo_mes_id uuid;
  v_venc_str text;
begin
  select mes_referencia into v_mes_ref from meses where id = p_mes_id;

  for i in 1..p_meses loop
    v_proximo_mes := to_char(
      (to_date(v_mes_ref, 'YYYY-MM') + (i || ' months')::interval),
      'YYYY-MM'
    );

    select id into v_proximo_mes_id
    from meses
    where usuario_id = p_usuario_id and mes_referencia = v_proximo_mes;

    if v_proximo_mes_id is null then
      insert into meses (usuario_id, mes_referencia, saldo_inicial, vencimento_cartao, saldo_minimo, meta_economia, arquivado)
      values (p_usuario_id, v_proximo_mes, 0, 10, 500, 1000, false)
      returning id into v_proximo_mes_id;
    end if;

    v_venc_str := lpad(p_vencimento_dia::text, 2, '0') || '/' ||
                  to_char(to_date(v_proximo_mes, 'YYYY-MM'), 'MM/YYYY');

    insert into boletos (mes_id, usuario_id, vencimento, dia, descricao, valor, status, recorrente, grupo_recorrencia)
    values (v_proximo_mes_id, p_usuario_id, v_venc_str, p_vencimento_dia, p_descricao, p_valor, 'prev', true, p_grupo_recorrencia)
    on conflict do nothing;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

-- ─── ATUALIZAR TRIGGER DE CRIACAO DE USUARIO PARA GERAR OS 12 MESES ──────────
create or replace function handle_new_user()
returns trigger as $$
begin
  insert into public.perfis (id, nome)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nome', split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;

  perform gerar_meses_usuario(new.id);

  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure handle_new_user();

-- ─── GERAR OS 12 MESES PARA USUARIOS JA EXISTENTES ───────────────────────────
do $$
declare
  u record;
begin
  for u in select id from auth.users loop
    perform gerar_meses_usuario(u.id);
  end loop;
end;
$$;

-- ─── ARQUIVAR MESES JA PASSADOS ──────────────────────────────────────────────
select arquivar_meses_passados();
