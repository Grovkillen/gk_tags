// Revision: 0.00.008
// The script is loaded only with gui_stuff, after its kernel and primitives, so it uses them without asking first.
// The marks in the issue's head are drawn by the server through the hook after the author line; the script no longer
// moves them there.
// The tag field is gui_stuff's chooser, so the datalist completer is gone; the tag's page has a
// form per box, so the question before a merge is its popover box; the heading's pill and the parent's path follow
// the fields before Save; form D puts each bar last in its row. The full focus opens in gui_stuff's upper layer (a
// menu entry never opens a popover), and the marks' own surface and panel are gone: the plus is gui_stuff's popover.
// gk_tags. Plain JavaScript, no jQuery.
// The box Taggar in the sidebar. Each type's group folds and unfolds and is remembered in the
// browser; the pills are buttons (Space presses them). Over the box's limit it turns into form D: a bar per tag, search,
// sorting and the top per type with Visa alla.
(function () {
  // A POST with the page's token, as core's links with data-method do
  function post(url, fields) {
    var f = document.createElement('form');
    f.method = 'post'; f.action = url; f.style.display = 'none';
    var meta = document.querySelector('meta[name="csrf-token"]');
    var all = Object.assign({ authenticity_token: meta ? meta.getAttribute('content') : '' }, fields || {});
    Object.keys(all).forEach(function (k) {
      var i = document.createElement('input'); i.type = 'hidden'; i.name = k; i.value = all[k]; f.appendChild(i);
    });
    document.body.appendChild(f);
    f.submit();
  }

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  // The box of the full focus (gui_stuff's primitives): the words, the issues now in focus in a table, each
  // with Byt ut, which replaces that one with this issue in the same step, and Avbryt, which closes the layer
  function chooser(d, cancel) {
    var t = d.t || {};
    var f = document.createDocumentFragment(), tb = el('tbody'), tab = el('table', 'gk-gui-stuff-popover-table');
    f.appendChild(el('p', null, t.intro || ''));
    (d.items || []).forEach(function (it) {
      var tr = el('tr'), td = el('td', null, it.subject ? '#' + it.id + ' ' + it.subject : '#' + it.id + ' ' + (t.hidden || ''));
      var meta = [it.priority, it.due ? (t.due || '') + ' ' + it.due : (t.no_due || '')].filter(function (x) { return x; }).join(', ');
      if (meta) { td.appendChild(document.createTextNode(' ')); td.appendChild(el('span', 'gk-gui-stuff-popover-hint', meta)); }
      var b = el('button', null, t.replace || '');
      b.type = 'button';
      b.title = (t.replace || '') + ' #' + it.id;
      b.addEventListener('click', function () { post(d.add, { replace: String(it.id) }); });
      tr.appendChild(td);
      tr.appendChild(el('td')).appendChild(b);
      tb.appendChild(tr);
    });
    tab.appendChild(tb);
    f.appendChild(tab);
    var bar = el('div', 'gk-gui-stuff-popover-buttons'), c = el('button', null, t.cancel || '');
    c.type = 'button';
    c.setAttribute('data-gk-gui-popover-cancel', '1');
    c.addEventListener('click', cancel);
    bar.appendChild(c);
    f.appendChild(bar);
    return f;
  }

  // The focus row in gui_stuff's actions_menu (kind action): on and off post the row's address (focus_remove or
  // focus_add); full (the row then ends with "…") opens the issues in focus in a surface in gui_stuff's upper layer,
  // under the menu's button when the row is in the three-dot menu, else under the row's own button. An entry in a menu
  // never opens a fold-out box.
  function focusChoose(link) {
    var d = window.gkGuiStuffPage && window.gkGuiStuffPage.data && window.gkGuiStuffPage.data.tg_focus;
    if (!d || d.state !== 'full') { post(link.href); return; }
    var menu = link.closest('.drdn'), at = (menu && menu.querySelector('.drdn-trigger')) || link, layer = null;
    layer = window.GkGui.layer.open({ key: 'tg-focus', title: (d.t && d.t.title) || '', anchor: at, opener: at,
                                      content: chooser(d, function () { if (layer) layer.close(true, 'x'); }) });
  }
  // Put on the shared actions now: the menu skips a row whose action is not there when it draws (this script is in
  // the head, after gui_stuff's kernel, and only while gui_stuff is there)
  window.GkGui.actions.tg_focus_choose = focusChoose;

  // The tag's page: the pill in the heading takes the role the marking and the type give it while they are
  // chosen, before Save; the parent's path under its field follows the chosen parent
  function tagPage() {
    var head = document.getElementById('gk-tags-head-pill'), form = document.getElementById('gk-tags-box-tag'), G = window.GkGui;
    var pill = head && head.querySelector('.gk-gui-stuff-pill');
    if (!form) return;
    if (pill) {
      // The marking is in the box Taggen for a managed tag, in the popover of Gör administrerad for any other
      var paint = function (m) {
        var t = form.querySelector('#gk_tags_type_id'), o = t && t.options[t.selectedIndex];
        var role = (m && m.value) || head.dataset.gkTagsCategory || (o ? o.dataset.gkTagsRole : head.dataset.gkTagsTypeRole);
        pill.className = pill.className.replace(/(^| )gk-gui-stuff-(cat|alert|role)-\S+/g, '').trim();
        var c = G.roleClass(role);
        if (c) pill.classList.add(c);
      };
      form.addEventListener('change', function () { paint(form.querySelector('#tag_marking')); });
      var promote = document.getElementById('gk-tags-box-promote');
      if (promote) promote.addEventListener('change', function () { paint(promote.querySelector('#gk_tags_promote_marking')); });
    }
    var parent = form.querySelector('#gk_tags_parent'), path = document.getElementById('gk-tags-path-now');
    if (parent && path) {
      parent.addEventListener('change', function () {
        var o = parent.options[parent.selectedIndex], own = path.dataset.gkTagsOwn || '';
        var above = o && o.value ? (o.dataset.gkTagsPath || o.value) : '';
        path.textContent = above ? above + '/' + own : own;
      });
    }
  }

  // The box Taggar (GkTags::Sidebar). A type's group folded or not is kept per type in the browser, as the reader
  // left it.
  function remember(key, value) {
    try { if (value == null) window.localStorage.removeItem(key); else window.localStorage.setItem(key, value); } catch (e) { /* private mode */ }
  }
  function recall(key) {
    try { return window.localStorage.getItem(key); } catch (e) { return null; }
  }

  function sidebar(box) {
    if (box.dataset.gkTagsBound) return;
    box.dataset.gkTagsBound = '1';
    var t = {};
    try { t = JSON.parse(box.dataset.gkTagsTexts || '{}'); } catch (e) { t = {}; }
    var types = Array.prototype.slice.call(box.querySelectorAll('.gk-tags-sb-type'));

    types.forEach(function (sec) {
      var btn = sec.querySelector('.gk-tags-sb-toggle');
      var list = sec.querySelector('.gk-tags-sb-list');
      var key = 'gkTags.sidebar.' + sec.dataset.gkTagsType;
      var set = function (open) {
        btn.setAttribute('aria-expanded', open ? 'true' : 'false');
        list.hidden = !open;
        var more = sec.querySelector('.gk-tags-sb-more');
        if (more) more.hidden = !open || box.classList.contains('gk-tags-sb-searching');
      };
      sec.gkSet = set;
      set(recall(key) !== 'closed');
      btn.addEventListener('click', function () {
        var open = btn.getAttribute('aria-expanded') !== 'true';
        set(open);
        remember(key, open ? null : 'closed');
      });
    });

    // a pill is a button that follows its link: Space presses it as Enter does
    box.addEventListener('keydown', function (e) {
      var a = e.target.closest && e.target.closest('a[role="button"]');
      if (a && (e.key === ' ' || e.key === 'Spacebar')) { e.preventDefault(); a.click(); }
    });

    var rows = Array.prototype.slice.call(box.querySelectorAll('.gk-tags-sb-row'));
    var limit = parseInt(box.dataset.gkTagsLimit, 10) || 15;
    if (rows.length <= limit) return;

    // Form D
    box.classList.add('gk-tags-sb-d');
    var top = parseInt(box.dataset.gkTagsTop, 10) || 5;
    var max = rows.reduce(function (m, r) { return Math.max(m, parseInt(r.dataset.gkTagsN, 10) || 0); }, 1);
    rows.forEach(function (r) {
      var bar = el('span', 'gk-tags-sb-bar');
      bar.setAttribute('aria-hidden', 'true');
      var fill = el('span');
      fill.style.inlineSize = Math.round(100 * (parseInt(r.dataset.gkTagsN, 10) || 0) / max) + '%';
      bar.appendChild(fill);
      r.appendChild(bar);
    });
    var groups = box.querySelector('.gk-tags-sb-groups');
    var scale = el('div', 'gk-tags-sb-scale');
    scale.title = t.scale || '';
    scale.appendChild(el('span', null, '0'));
    scale.appendChild(el('span', null, String(max)));
    groups.insertBefore(scale, groups.firstChild);

    var tools = el('div', 'gk-tags-sb-tools');
    var search = el('input');
    search.type = 'search';
    search.placeholder = t.search || '';
    search.setAttribute('aria-label', t.search || '');
    var sort = el('select');
    sort.setAttribute('aria-label', t.sort || '');
    [['count', t.by_count], ['name', t.by_name]].forEach(function (o) {
      var opt = el('option', null, o[1] || o[0]);
      opt.value = o[0];
      sort.appendChild(opt);
    });
    tools.appendChild(search);
    tools.appendChild(sort);
    box.insertBefore(tools, groups);
    var none = el('p', 'gk-tags-sb-none', t.none || '');
    none.hidden = true;
    box.appendChild(none);

    // per type: the top rows, and Visa alla N / Visa färre for the rest
    types.forEach(function (sec) {
      var list = sec.querySelector('.gk-tags-sb-list');
      var n = list.children.length;
      sec.gkAll = false;
      if (n <= top) return;
      var more = el('button', 'gk-tags-sb-more');
      more.type = 'button';
      more.setAttribute('aria-controls', list.id);
      more.addEventListener('click', function () { sec.gkAll = !sec.gkAll; apply(); });
      sec.appendChild(more);
    });

    function apply() {
      var q = search.value.trim().toLowerCase();
      var by = sort.value;
      var any = false;
      box.classList.toggle('gk-tags-sb-searching', q !== '');
      types.forEach(function (sec) {
        var list = sec.querySelector('.gk-tags-sb-list');
        var items = Array.prototype.slice.call(list.children);
        items.sort(function (a, b) {
          var na = a.dataset.gkTagsName.toLowerCase(), nb = b.dataset.gkTagsName.toLowerCase();
          if (by === 'name') return na < nb ? -1 : na > nb ? 1 : 0;
          return (parseInt(b.dataset.gkTagsN, 10) - parseInt(a.dataset.gkTagsN, 10)) || (na < nb ? -1 : na > nb ? 1 : 0);
        });
        items.forEach(function (li) { list.appendChild(li); });
        var shown = 0;
        items.forEach(function (li, i) {
          var hit = q === '' || li.dataset.gkTagsName.toLowerCase().indexOf(q) >= 0;
          li.hidden = q === '' ? (!sec.gkAll && i >= top) : !hit;
          if (hit) shown += 1;
        });
        // while searching a type without a hit is folded away
        sec.hidden = q !== '' && shown === 0;
        if (!sec.hidden) any = true;
        var more = sec.querySelector('.gk-tags-sb-more');
        if (more) {
          more.textContent = sec.gkAll ? (t.fewer || '') : (t.all || '').replace('%{count}', items.length);
          more.setAttribute('aria-expanded', sec.gkAll ? 'true' : 'false');
          more.hidden = q !== '' || sec.querySelector('.gk-tags-sb-toggle').getAttribute('aria-expanded') !== 'true';
        }
      });
      none.hidden = any;
      scale.hidden = !any;
    }
    search.addEventListener('input', apply);
    sort.addEventListener('change', apply);
    apply();
  }

  function start() {
    tagPage();
    document.querySelectorAll('.gk-tags-sidebar').forEach(sidebar);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
