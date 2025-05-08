"streamlit run painel_mes"

import streamlit as st
import pandas as pd
import requests
import plotly.express as px
from datetime import datetime, timedelta
import time

# ========== CONFIGURAÇÕES ========== #
st.set_page_config(page_title="Painel MES", layout="wide")

API_URL = "https://indicadores.tfleet.com.br/api/service-import/OcupacaoHoje"
ACESSO = "141979"  # substitua pelo seu código real
TOKEN = "VesrecD#$2302930$fj"  # substitua pelo token real
MAX_PASSAGEIROS = 45

# ========== ESTADO INICIAL ==========
if "fixar" not in st.session_state:
    st.session_state.fixar = False
if "linha_fixa" not in st.session_state:
    st.session_state.linha_fixa = None
if "filtros_limpando" not in st.session_state:
    st.session_state.filtros_limpando = False

@st.cache_data(ttl=300)
def carregar_dados():
    try:
        body = {"acesso": ACESSO, "token": TOKEN}
        response = requests.post(API_URL, json=body)
        if response.status_code == 200:
            return pd.DataFrame(response.json()["result"])
        else:
            st.error("Erro ao acessar API.")
            return pd.DataFrame()
    except:
        st.error("Erro ao carregar dados.")
        return pd.DataFrame()

# ========== CARGA E AJUSTE ========== #
df = carregar_dados()

if not df.empty:
    df['data'] = pd.to_datetime(df['data'], format="%d/%m/%Y", errors='coerce')
    df['data_str'] = df['data'].dt.strftime("%d/%m")
    df['tipolinha'] = df['tipolinha'].fillna('').str.strip()
    df['tipoviagem'] = df['tipoviagem'].fillna("NÃO DEFINIDO")

    # ===== FILTROS DINÂMICOS =====
    filtro_tipo_linha = ["ADM", "TURNO 01 12X12", "TURNO 02 12X12"]
    df = df[df['tipolinha'].isin(filtro_tipo_linha)]

    datas_disponiveis = df['data'].dropna().dt.date.sort_values().unique()
    hoje = datetime.now().date()
    data_padrao = hoje if hoje in datas_disponiveis else datas_disponiveis[-1]

    if st.session_state.filtros_limpando:
        data_selecionada = data_padrao
        linha_selecionada = []
        viagem_selecionada = []
        st.session_state.filtros_limpando = False
    else:
        colf1, colf2, colf3 = st.columns(3)
        data_selecionada = colf1.selectbox("📅 Data", datas_disponiveis, index=list(datas_disponiveis).index(data_padrao))
        linha_selecionada = colf2.multiselect("🚌 Tipo de Linha", sorted(df['tipolinha'].dropna().unique()))
        viagem_selecionada = colf3.multiselect("🕒 Tipo de Viagem", sorted(df['tipoviagem'].dropna().unique()))

    filtro = df.copy()
    if data_selecionada:
        filtro = filtro[filtro['data'].dt.date == data_selecionada]
    if linha_selecionada:
        filtro = filtro[filtro['tipolinha'].isin(linha_selecionada)]
    if viagem_selecionada:
        filtro = filtro[filtro['tipoviagem'].isin(viagem_selecionada)]

    # ===== FIXAR LINHA =====
    with st.expander("🔒 Fixar Linha Específica"):
        colfix, coltoggle = st.columns([4, 1])
        linha_fixa = colfix.selectbox("Fixar Linha", options=[None] + list(df['linha'].unique()))
        coltoggle.button("Fixar/Desfixar", on_click=lambda: st.session_state.update({
            'fixar': not st.session_state.fixar,
            'linha_fixa': linha_fixa
        }))

    if st.session_state.fixar and st.session_state.linha_fixa:
        filtro = filtro[filtro['linha'] == st.session_state.linha_fixa]
        st.success(f"Linha fixada: {st.session_state.linha_fixa}")

    # ===== INDICADORES =====
    qtd_passag = len(filtro)
    qtd_rotas = filtro['linha'].nunique()
    st.markdown("## 🔍 Visão Geral")
    col1, col2 = st.columns(2)
    col1.metric("👥 Qtd. Passageiros", qtd_passag)
    col2.metric("🛣️ Qtd. Rotas", qtd_rotas)

    # ===== STATUS =====
    st.markdown("### 🧭 Status de Utilização")
    status_counts = filtro['tipopassageiro'].value_counts().reset_index()
    status_counts.columns = ['Status', 'Qtd']
    fig_pie = px.pie(status_counts, names='Status', values='Qtd', hole=0.4)
    st.plotly_chart(fig_pie, use_container_width=True)

    # ===== LETREIRO ANIMADO =====
    st.markdown("### 🪧 Letreiro de Ocupação")
    por_linha = filtro.groupby('linha').size().reset_index(name='qtdpassag')
    por_linha['porcen'] = round((por_linha['qtdpassag'] / MAX_PASSAGEIROS) * 100)

    msg1 = " ➜ ".join([f"{row['linha']} - {row['qtdpassag']}" for _, row in por_linha.iterrows()])
    msg2 = " ➜ ".join([f"{row['linha']} - {row['porcen']}%" for _, row in por_linha.iterrows()])

    st.markdown(f"""
    <marquee behavior="scroll" direction="left" scrollamount="6" style="color:orange;font-size:18px">📢 {msg1}</marquee>
    <marquee behavior="scroll" direction="left" scrollamount="6" style="color:green;font-size:18px">📢 {msg2}</marquee>
    """, unsafe_allow_html=True)

    # ===== POR TIPO DE LINHA =====
    st.markdown("### 🧮 Passageiros por Tipo de Linha")
    por_tipo = filtro.groupby('tipolinha').size().reset_index(name='Qtd')
    fig_bar = px.bar(por_tipo, x='tipolinha', y='Qtd', color='tipolinha', text='Qtd')
    st.plotly_chart(fig_bar, use_container_width=True)

    # ===== HISTÓRICO DE 5 DIAS =====
    st.markdown("### 📈 Histórico dos últimos 5 dias da data selecionada")
    data_base = data_selecionada
    ultimos_dias = df[(df['data'] >= pd.to_datetime(data_base) - timedelta(days=4)) & (df['data'] <= pd.to_datetime(data_base))]
    linha_dia = ultimos_dias.groupby('data_str').size().reset_index(name='Qtd')
    fig_linha = px.line(linha_dia, x='data_str', y='Qtd', markers=True)
    st.plotly_chart(fig_linha, use_container_width=True)

    # ===== DETALHAMENTO =====
    st.markdown("### 📋 Detalhamento")
    st.dataframe(filtro[['tipopassageiro','hora', 'nome', 'empresa', 'linhapassageiro']])

    # ===== BOTÃO LIMPAR FILTROS =====
    if st.button("🔄 Limpar todos os filtros"):
        st.session_state.filtros_limpando = True
        st.experimental_rerun()

else:
    st.warning("Nenhum dado disponível.")
