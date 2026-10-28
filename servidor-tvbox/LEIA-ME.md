# Servidor da TV Box (Monitor Frota)

Um servidor só, na TV Box TX9 (S905X) com Armbian, rodando todos os fluxos: alerta do roteador, coleta e relatórios de lotação, ocorrências do WhatsApp e os próximos. Custo: R$ 0 por mês.

## O que roda na box

| Programa | Para que serve | Endereço |
| --- | --- | --- |
| Central da Frota (Cockpit) | Interface: fluxos, WhatsApp, arquivos, rede, backup, terminal | `https://IP:9090` |
| n8n | Editor visual dos fluxos | `http://IP:5678` |
| Evolution API | Conexão com o WhatsApp (QR code) | `http://IP:8080/manager` |
| Tailscale | Acesso de qualquer lugar sem abrir porta no roteador | app no celular/PC |

`IP` = o IP de casa (ex.: 192.168.0.25) ou o IP do Tailscale (100.x.x.x) quando estiver fora.

## Antes de começar (você)

1. n8n Cloud: alerta do roteador a cada 1 hora (para não acabar as execuções do teste).
2. n8n Cloud: baixar cada fluxo (⋯ → Download) para uma pasta do PC. Não mandar no chat (tem token e chave dentro).
3. Chave do Gemini: aistudio.google.com → Get API key → Create API key. Guardar.
4. Conta no Tailscale (tailscale.com, entrar com Google) e o app instalado no celular e no PC.
5. Senha de app do Gmail (myaccount.google.com → Segurança → Senhas de app), se não tiver anotada.
6. SD de 32 GB (A1 ou A2), leitor, cabo de rede, balenaEtcher no PC, chip do WhatsApp num celular reserva.

## Passo a passo

1. Gravar no SD a imagem `Armbian_..._amlogic_s905x-tx9_...server...img.gz` (ou a `s905x-t95` se não houver tx9) com o balenaEtcher.
2. Pôr o SD na box, cabo de rede ligado, e dar boot pelo SD (palito no furo do reset ao ligar).
3. Achar o IP da box no app do roteador e entrar por SSH: `ssh root@IP` (senha inicial 1234). O Armbian pede para criar a senha do root e um usuário. Esse usuário é o login da Central.
4. Rodar o instalador (um comando só, leva de 10 a 20 min):

   ```
   curl -fsSL https://raw.githubusercontent.com/zael20/painel-mes-tfleet-bdv/main/servidor-tvbox/instalar.sh | sudo bash
   ```

   No fim ele mostra a RAM real, um link do Tailscale para autorizar a box e os endereços.
5. Abrir o n8n (`http://IP:5678`) e criar o usuário dono.
6. Na Central (`https://IP:9090`): ativar o acesso administrativo e usar Importar fluxo com os .json baixados do Cloud. No n8n, recriar a credencial do Gmail (SMTP) em cada fluxo que manda e-mail e ligar os fluxos.
7. WhatsApp: abrir a tela do QR, criar a instância, ler o QR com o celular reserva e rodar no terminal `sudo servidor whatsapp` (pede a chave secreta do Supabase e a do Gemini, e o grupo).
8. Desligar os fluxos no n8n Cloud só depois de conferir que os da box rodaram certo (para não mandar e-mail duplicado).

## Comando de ajuda

No terminal (da Central ou SSH), digite `servidor`:

- `servidor status`: o que está rodando, RAM, cartão, temperatura
- `servidor logs n8n`: últimas linhas de log
- `sudo servidor backup`: backup agora (automático todo dia 03:00, guarda 14 dias)
- `sudo servidor atualizar`: versões novas do n8n e da Evolution (faz backup antes)
- `sudo servidor whatsapp`: configura o fluxo de ocorrências

## Cuidados

- Baixe um backup para o PC de vez em quando (Central → Arquivos → Backups → Baixar). Se o SD estragar, é ele que salva.
- O n8n guarda só as execuções com erro (para não encher o cartão).
- Nenhuma porta é aberta no roteador. O acesso de fora é só pelo Tailscale.
- Wi-Fi e Bluetooth podem não funcionar no Linux dessa box (depende do chip). O servidor usa o cabo.
