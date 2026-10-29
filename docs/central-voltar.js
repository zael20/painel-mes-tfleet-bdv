/* Botão flutuante "← Central" — injetado em cada painel.
   Um arquivo só: mexer aqui ajusta o botão em todos os painéis de uma vez.
   Cada painel carrega com: <script src="central-voltar.js"></script>
   (na pasta vistoria/ o src é ../central-voltar.js). */
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
      'position:fixed;left:12px;z-index:2147483000;display:inline-flex;align-items:center;' +
      'gap:6px;background:#2563eb;color:#fff;text-decoration:none;' +
      'font:600 14px system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;' +
      'padding:9px 14px;border-radius:999px;line-height:1;' +
      'box-shadow:0 2px 10px rgba(0,0,0,.28);cursor:pointer;' +
      'bottom:calc(14px + env(safe-area-inset-bottom,0px));' +
      'padding-left:calc(14px + env(safe-area-inset-left,0px));';
    a.onmouseenter = function () { a.style.background = '#1d4ed8'; };
    a.onmouseleave = function () { a.style.background = '#2563eb'; };
    document.body.appendChild(a);
  }

  if (document.body) add();
  else document.addEventListener('DOMContentLoaded', add);
})();
