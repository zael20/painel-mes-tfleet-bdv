/* Botão flutuante "← Central" — injetado em cada painel.
   Um arquivo só: mexer aqui ajusta o botão em todos os painéis de uma vez.
   Cada painel carrega com: <script src="central-voltar.js"></script>
   (na pasta vistoria/ o src é ../central-voltar.js).
   v3: canto superior esquerdo, maior; reserva espaço no topo (body.paddingTop,
   usado pela Vistoria) e AUTO-OCULTA ao rolar pra baixo / reaparece ao rolar
   pra cima — assim nunca cobre o conteúdo ao rolar a página. */
(function () {
  var p = (location.pathname || '').toLowerCase();
  // Não mostra na própria Central.
  if (/central\.html$/.test(p)) return;
  // Vistoria fica um nível abaixo (vistoria/index.html) -> precisa subir um nível.
  var prefix = /\/vistoria(\/|\/index\.html)?$/.test(p) || /\/vistoria\//.test(p) ? '../' : '';

  function add() {
    if (document.getElementById('tf-voltar-central')) return;
    var a = document.createElement('a');
    a.id = 'tf-voltar-central';
    a.href = prefix + 'central.html';
    a.textContent = '← Central';
    a.setAttribute('aria-label', 'Voltar à Central');
    a.style.cssText =
      'position:fixed;z-index:2147483000;display:inline-flex;align-items:center;' +
      'gap:8px;background:#2563eb;color:#fff;text-decoration:none;' +
      'font:800 17px system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;' +
      'padding:13px 22px;border-radius:999px;line-height:1;border:2px solid #fff;' +
      'box-shadow:0 4px 16px rgba(0,0,0,.35);cursor:pointer;' +
      'top:calc(10px + env(safe-area-inset-top,0px));' +
      'left:calc(12px + env(safe-area-inset-left,0px));' +
      'transition:transform .22s ease;';
    a.onmouseenter = function () { a.style.background = '#1d4ed8'; };
    a.onmouseleave = function () { a.style.background = '#2563eb'; };
    document.body.appendChild(a);
    reserveSpace(a);
    autoHideOnScroll(a);
  }

  // O botão é fixo (fica sempre visível). Pra ele NUNCA tampar o conteúdo
  // (ainda mais quando a janela está estreita), reservamos um espaço no topo
  // da página do tamanho do botão — assim ele fica "num lugar só dele".
  function reserveSpace(a) {
    try {
      var need = Math.ceil(a.getBoundingClientRect().bottom) + 8;
      var cur = parseFloat(getComputedStyle(document.body).paddingTop) || 0;
      if (cur < need) document.body.style.paddingTop = need + 'px';
    } catch (e) { /* layout exótico: no mínimo o botão continua visível */ }
  }

  // Ao rolar a página pra baixo, esconde o botão (sobe pra fora da tela) pra não
  // cobrir o conteúdo; ao rolar pra cima (ou perto do topo), ele volta. Continua
  // sempre acessível, mas nunca fica na frente do que você está lendo.
  function autoHideOnScroll(a) {
    var lastY = 0, hidden = false, ticking = false;
    function apply() {
      ticking = false;
      var y = window.pageYOffset || document.documentElement.scrollTop || 0;
      if (y > lastY && y > 80) {           // rolando pra baixo e já saiu do topo
        if (!hidden) { a.style.transform = 'translateY(-160%)'; hidden = true; }
      } else if (y < lastY || y <= 80) {   // rolando pra cima ou perto do topo
        if (hidden) { a.style.transform = 'none'; hidden = false; }
      }
      lastY = y;
    }
    window.addEventListener('scroll', function () {
      if (!ticking) { ticking = true; (window.requestAnimationFrame || setTimeout)(apply); }
    }, { passive: true });
  }

  if (document.body) add();
  else document.addEventListener('DOMContentLoaded', add);
})();
