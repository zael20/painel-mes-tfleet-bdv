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
      'position:fixed;z-index:2147483000;display:inline-flex;align-items:center;' +
      'gap:8px;background:#2563eb;color:#fff;text-decoration:none;' +
      'font:800 17px system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;' +
      'padding:13px 22px;border-radius:999px;line-height:1;border:2px solid #fff;' +
      'box-shadow:0 4px 16px rgba(0,0,0,.35);cursor:pointer;' +
      'top:calc(10px + env(safe-area-inset-top,0px));' +
      'left:calc(12px + env(safe-area-inset-left,0px));';
    a.onmouseenter = function () { a.style.background = '#1d4ed8'; };
    a.onmouseleave = function () { a.style.background = '#2563eb'; };
    document.body.appendChild(a);
  }

  if (document.body) add();
  else document.addEventListener('DOMContentLoaded', add);
})();
