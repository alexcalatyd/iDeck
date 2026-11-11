'use strict';

/* iDeck — el panel del movil.
   =======================================================================
   Cuatro cosas que explican la forma del fichero:

   1. No se sondea. El Mac empuja el estado por Server-Sent Events, asi que
      `render` se llama cuando algo cambia de verdad. Lo unico que corre en
      bucle aqui es el reloj y la interpolacion de la posicion de la pista.

   2. Todo control que el usuario pueda estar tocando reconcilia. Un slider
      no acepta el valor del servidor mientras el dedo esta encima ni en los
      instantes siguientes: ahi estaba el rebote del volumen. Ver `Reconcile`.

   3. Cada pantalla tiene UNA funcion. Mando son los controles del sistema,
      Apps son las apps, Suena es el reproductor y Ajustes es lo poco que
      tiene sentido tocar desde el movil. Nada se mezcla.

   4. La haptica se dispara en `pointerdown`, en un unico sitio para todos
      los elementos pulsables. Ver `Haptics`, que explica por que.
   ======================================================================= */

const token = new URLSearchParams(location.search).get('t') || localStorage.getItem('ideck.token') || '';
if (token) localStorage.setItem('ideck.token', token);

const $ = (id) => document.getElementById(id);
const body = document.body;
const t = (key) => L.t(key);

let state = {};
/* La firma de lo que obliga a volver a montar una pantalla. Repintarla en
   cada aviso robaria el toque en curso. */
let deckSignature = null;
let appsSignature = null;
let settingsSignature = null;
let currentArtURL = null;

/** La firma de un trozo de estado, con las claves ORDENADAS.

    No es una floritura. El Mac arma el estado con diccionarios de Swift y
    `JSONSerialization` los escribe en el orden que le da la gana: el mismo
    estado, sin un solo valor distinto, llega una vez como
    `{"sleep":true,"apps":true,...}` y a la siguiente como
    `{"apps":true,"sleep":true,...}`. Con `JSON.stringify` a pelo eso son
    dos firmas distintas, asi que el Mando se desmontaba y se volvia a
    montar en CADA aviso del Mac: la pagina saltaba a la primera y, si el
    dedo estaba encima de algo, el nodo que tocaba desaparecia a mitad del
    gesto. Ordenando las claves, el mismo estado da la misma firma.

    En el Mac tambien se manda ya ordenado; esto es el cinturon del
    tirante, porque un panel abierto puede ser mas viejo que el servidor. */
function stamp(value) {
  return JSON.stringify(value, (key, raw) => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return raw;
    return Object.fromEntries(Object.keys(raw).sort().map((name) => [name, raw[name]]));
  });
}

/* --- Transporte -------------------------------------------------------- */

function url(path) {
  return path + (path.includes('?') ? '&' : '?') + 't=' + encodeURIComponent(token);
}

/** Devuelve si el Mac acepto la accion: la isla solo confirma lo que ha
    pasado de verdad. */
async function send(id, value) {
  try {
    const response = await fetch(url('/api/action'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(value === undefined ? { id } : { id, value }),
    });
    if (!response.ok) { offline(response.status); return false; }
    render(await response.json());
    return true;
  } catch {
    offline();
    return false;
  }
}

async function pull() {
  try {
    const response = await fetch(url('/api/state'));
    if (!response.ok) return offline(response.status);
    render(await response.json());
  } catch {
    offline();
  }
}

/* El canal de avisos. `EventSource` reconecta solo, pero iOS congela la
   conexion al irse a segundo plano y a veces no vuelve: de eso se encarga
   el `visibilitychange` de abajo. */
let events = null;

function connect() {
  if (events) events.close();
  events = new EventSource(url('/api/events'));
  events.addEventListener('state', (event) => {
    try { render(JSON.parse(event.data)); } catch { /* trama a medias */ }
  });
  events.onerror = () => {
    // No se cierra: readyState pasa a CONNECTING y el navegador reintenta.
    if (events.readyState === EventSource.CLOSED) offline();
  };
}

/* Perder el Mac se dice en la isla, pero con calma: al volver del segundo
   plano iOS tarda un instante en recuperar la red y la primera peticion
   falla casi siempre. Solo si sigue caido pasado un momento se avisa, y solo
   si se aviso se celebra la vuelta. */
const Link = { lostTimer: null, warned: false };

function offline(status) {
  const wasLive = body.classList.contains('is-live');
  body.classList.remove('is-live', 'is-booting');
  body.classList.add('is-stale');
  renderLink(t(status === 401 ? 'link.expired' : 'link.offline'), false);
  if (!wasLive || Link.lostTimer || Link.warned) return;
  Link.lostTimer = setTimeout(() => {
    Link.lostTimer = null;
    if (!body.classList.contains('is-stale')) return;
    Link.warned = true;
    Island.show({ text: t(status === 401 ? 'link.expired' : 'island.offline'), icon: 'wifi-off', tone: 'warn', ms: 3200 });
  }, 1600);
}

function backOnline() {
  if (Link.lostTimer) { clearTimeout(Link.lostTimer); Link.lostTimer = null; }
  if (!Link.warned) return;
  Link.warned = false;
  Island.show({ text: t('island.back'), icon: 'wifi', tone: 'good' });
}

/* --- Isla ---------------------------------------------------------------
   El acuse de lo que pasa en el Mac y no se ve desde el movil: bloquearlo,
   apagar la pantalla, abrir una app, perder la conexion. Una a la vez, como
   las notificaciones con limite de Mantine: la nueva cambia el contenido de
   la que ya esta abierta en vez de apilarse. `role="status"` la lee
   VoiceOver sin robar el foco. */

const Island = {
  timer: null,
  hideTimer: null,

  show(options) {
    const node = $('island');
    const art = $('island-art');
    const open = !node.hidden && node.classList.contains('is-on');

    art.textContent = '';
    art.className = 'island-art';
    if (options.image) {
      const img = new Image();
      img.alt = '';
      img.draggable = false;
      img.onerror = () => img.remove();
      img.src = options.image;
      art.append(img);
      art.classList.add('is-app');
    } else if (options.icon) {
      art.innerHTML = '<svg aria-hidden="true"><use href="#i-' + options.icon + '"/></svg>';
    }
    $('island-text').textContent = options.text;
    node.classList.toggle('is-warn', options.tone === 'warn');
    node.classList.toggle('is-good', options.tone === 'good');

    clearTimeout(this.timer);
    clearTimeout(this.hideTimer);
    node.hidden = false;
    if (open) {
      node.classList.remove('is-swapping');
      void node.offsetWidth;
      node.classList.add('is-swapping');
    } else {
      // Un fotograma en su forma recogida, o el muelle no tiene de donde salir.
      void node.offsetWidth;
      requestAnimationFrame(() => node.classList.add('is-on'));
    }
    this.timer = setTimeout(() => this.hide(), options.ms || 2200);
  },

  hide() {
    const node = $('island');
    node.classList.remove('is-on', 'is-swapping');
    this.hideTimer = setTimeout(() => { node.hidden = true; }, 320);
  },
};

/* El nombre del servidor no es una traduccion y no puede llevar `data-t`:
   `L.paint` lo pisaba con "Conectando" cada vez que se repintaba el
   idioma, y el panel se quedaba diciendo que seguia conectando. */
function renderLink(text, live) {
  $('link-text').textContent = text;
  $('link').querySelector('use').setAttribute('href', live ? '#i-wifi' : '#i-wifi-off');
}

/* --- Haptica -----------------------------------------------------------
   Hay dos motores posibles y ninguno de los dos es universal:

   - Android y Chrome tienen la Vibration API (`navigator.vibrate`).
   - Safari NO la implementa, ni en iOS 26. El unico camino al motor es un
     `<input type="checkbox" switch>` conmutado por su etiqueta: desde iOS
     17.4 eso dispara el toque del sistema.

   Lo que se hace para que el segundo camino responda:

   1. Dos montajes del mismo truco, porque WebKit ha cambiado de opinion
      entre versiones sobre cual cuenta: uno con la etiqueta en el `<head>`
      y `display: none` (la receta de iOS 17.4) y otro RENDERIZADO dentro
      del `<body>`, de 1 px y casi transparente pero dentro del viewport
      (desde iOS 18 hay versiones que descartan el conmutado de un control
      que no se dibuja). Nada de `z-index: -1`: detras del fondo tampoco
      cuenta como dibujado.
   2. Si pulsar la ETIQUETA no conmuta, se pulsa el propio input. Son dos
      caminos de activacion distintos y no siempre valen los dos.
   3. Se pide en `pointerdown`, que concede activacion de usuario, y de
      forma sincrona: nada de `await` ni `setTimeout` por el medio. Con
      `click` llegaba al final del gesto y WebKit lo descartaba.
   4. Un unico disparador para toda la interfaz, asi que un control nuevo
      lo hereda sin que haya que acordarse.

   Y lo que de verdad hacia falta: SABER si el panel esta haciendo su parte.
   Se cuentan los toques pedidos y los que han conmutado el interruptor de
   verdad (el evento `change` llega sincrono dentro del `click`). Ajustes
   ensena las dos cifras. Si conmuta y no se nota nada, el que calla es el
   telefono —la haptica del sistema apagada, o el modo de bajo consumo, que
   la desactiva entera— y no el codigo. Sin esa cifra, un fallo del sistema y
   un fallo del panel se parecen y no hay por donde tirar. */

const Haptics = {
  enabled: true,
  /** "vibrate", "switch" o "none". Se ensena en Ajustes tal cual. */
  engine: 'none',
  /** Los conmutadores de WebKit. Hay dos, a proposito; ver arriba. */
  switches: [],
  last: 0,
  /** Toques pedidos y conmutados de verdad. El diagnostico de Ajustes. */
  asked: 0,
  flipped: 0,
  /** Avisa a Ajustes de que las cifras han cambiado. */
  onReport: null,

  init() {
    if (typeof navigator.vibrate === 'function') {
      this.engine = 'vibrate';
      return;
    }
    const probe = document.createElement('input');
    probe.type = 'checkbox';
    // La propiedad solo existe donde el conmutador existe de verdad; un
    // atributo que no se refleja significa que no hay motor por aqui.
    if (!('switch' in probe)) return;
    this.switches = [this.makeSwitch(document.head, true), this.makeSwitch(document.body, false)];
    this.engine = 'switch';
  },

  makeSwitch(host, hidden) {
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.setAttribute('switch', '');
    input.tabIndex = -1;
    // `change` llega sincrono dentro del `click`, asi que contarlo aqui dice
    // si el conmutado ha ocurrido de verdad o lo ha descartado WebKit.
    input.addEventListener('change', () => { this.flipped += 1; });
    const label = document.createElement('label');
    label.setAttribute('aria-hidden', 'true');
    label.className = 'haptic-probe';
    if (hidden) label.style.display = 'none';
    label.append(input);
    host.append(label);
    return { label, input };
  },

  get available() { return this.engine !== 'none'; },

  /** Lo que Ajustes ensena debajo de la fila. */
  get report() { return { engine: this.engine, asked: this.asked, flipped: this.flipped }; },

  /** Un toque. `ms` solo lo usa la Vibration API; el de iOS es fijo. */
  tap(ms) {
    if (!this.enabled || this.engine === 'none') return;
    // Un slider dispara muchos avisos; sin freno la haptica se vuelve un
    // zumbido continuo, que es justo lo que no se quiere.
    const now = performance.now();
    if (now - this.last < 26) return;
    this.last = now;
    this.asked += 1;

    if (this.engine === 'vibrate') {
      // Nunca mas de 15 ms: lo que se busca es el golpecito de iOS, no el
      // zumbido de una notificacion.
      try { navigator.vibrate(Math.min(15, ms || 9)); } catch { /* puede negarse */ }
      if (this.onReport) this.onReport();
      return;
    }

    const before = this.flipped;
    for (const probe of this.switches) {
      try { probe.label.click(); } catch { /* sin gesto de usuario detras */ }
    }
    // Si la etiqueta no ha conmutado nada, se prueba con el propio control:
    // son dos caminos de activacion distintos y no valen los dos en todas
    // las versiones de WebKit.
    if (this.flipped === before) {
      for (const probe of this.switches) {
        try { probe.input.click(); } catch { /* idem */ }
      }
    }
    if (this.onReport) this.onReport();
  },
};

Haptics.init();

/* --- Pulsacion ---------------------------------------------------------
   El hundimiento empieza en `pointerdown` y dura un minimo visible, para
   que un toque rapido tambien se vea. `:active` no sirve: se cancela al
   deslizar y deja el boton sin acuse.

   Este es tambien el unico sitio donde se pide la haptica. */

const PRESSABLE = '.orb, .strip, .key, .tab, .app-tile, .sheet-button, .row.is-tap, .stepper-half';
const pressed = new Map();

function press(node) {
  node.classList.add('is-press');
  pressed.set(node, performance.now());
}

function release(node) {
  const since = performance.now() - (pressed.get(node) || 0);
  pressed.delete(node);
  const wait = Math.max(0, 110 - since);
  setTimeout(() => node.classList.remove('is-press'), wait);
}

/** Interruptores y segmentados que el dedo tiene cogidos. No usan
    `is-press`, que los encogeria: su forma de decir "te tengo" es otra (el
    pomo se ensancha, la pieza elegida se encoge). */
const held = new Set();

document.addEventListener('pointerdown', (event) => {
  const node = event.target.closest(PRESSABLE + ', .switch, .segment-option, .slider, .scrub');
  if (!node || node.disabled || node.classList.contains('is-disabled')) return;
  const grip = event.target.closest('.switch, .segment-option');
  if (grip) { grip.classList.add('is-held'); held.add(grip); }
  // Sincrono y dentro del gesto: es lo que hace que el motor responda.
  Haptics.tap(9);
  const pressable = event.target.closest(PRESSABLE);
  if (pressable && !pressable.disabled) press(pressable);
}, { passive: true });

for (const name of ['pointerup', 'pointercancel', 'pointerleave']) {
  document.addEventListener(name, (event) => {
    // `pointerleave` del propio documento (el puntero sale de la ventana)
    // llega con `document` de objetivo, que no tiene `closest`.
    const node = event.target.closest ? event.target.closest(PRESSABLE) : null;
    if (node && pressed.has(node)) release(node);
    // Deslizar fuera del boton tambien tiene que soltarlo.
    if (name === 'pointerup') for (const other of [...pressed.keys()]) release(other);
    if (name !== 'pointerleave') {
      for (const grip of held) grip.classList.remove('is-held');
      held.clear();
    }
  }, { passive: true });
}

/* Las acciones que no dejan rastro (bloquear, captura, Mission Control)
   necesitan decir que salieron. */
function acknowledge(node) {
  node.classList.remove('did-fire');
  void node.offsetWidth;
  node.classList.add('did-fire');
}

/* --- Reconciliacion ----------------------------------------------------
   El patron que arregla el rebote. Mientras el usuario manda, el valor
   local es la verdad; el del servidor solo se acepta cuando confirma el
   cambio o cuando se agota la espera. Sin esto, la respuesta de una
   peticion en vuelo (con el valor de ANTES de escribir) pisaba el dedo. */

class Reconcile {
  constructor(tolerance) {
    this.tolerance = tolerance === undefined ? 1 : tolerance;
    this.pending = null;
    this.until = 0;
  }

  /// Lo que acabamos de mandar al Mac.
  expect(value, ms) {
    this.pending = value;
    this.until = performance.now() + (ms || 700);
  }

  /// `true` si hay que hacer caso al valor que llega.
  accepts(value) {
    if (this.pending === null) return true;
    const matched = typeof value === 'number' && typeof this.pending === 'number'
      ? Math.abs(value - this.pending) <= this.tolerance
      : value === this.pending;
    if (matched || performance.now() > this.until) {
      this.pending = null;
      return true;
    }
    return false;
  }
}

/* --- Estiron elastico --------------------------------------------------
   Pasarse del final de un nivel no deja el dedo en el vacio: la pastilla se
   estira hacia el dedo, cada vez menos cuanto mas se tira, y vuelve con
   muelle al soltar. Es lo que hacen los sliders de Centro de Control, y
   dice "ya esta al maximo" sin numero ni texto.

   `over` son los pixeles que el dedo se ha salido. Devuelve lo que crece el
   eje largo (como mucho un 9 %) y lo que adelgaza el corto. */
function rubber(over) {
  const grow = 1 + 0.09 * (1 - Math.exp(-over / 90));
  return { grow, thin: 1 - (grow - 1) * 0.35 };
}

/** Aplica el estiron a `node` a lo largo de `axis`. `edge` es el lado del que
    tira el dedo ('start' arriba o a la izquierda, 'end' abajo o a la derecha)
    y la pieza crece desde el lado contrario. */
function stretch(node, axis, over, edge) {
  clearTimeout(node.relaxTimer);
  if (!over) { node.style.scale = ''; return; }
  const { grow, thin } = rubber(over);
  const anchor = edge === 'start' ? (axis === 'v' ? 'bottom' : 'right') : (axis === 'v' ? 'top' : 'left');
  node.style.transformOrigin = axis === 'v' ? 'center ' + anchor : anchor + ' center';
  node.style.scale = axis === 'v' ? thin + ' ' + grow : grow + ' ' + thin;
}

/** Suelta el estiron. El origen se queda hasta que acaba el muelle de vuelta,
    o la pieza saltaria de sitio a medio camino. */
function relax(node) {
  if (!node.style.scale) return;
  node.style.scale = '';
  clearTimeout(node.relaxTimer);
  node.relaxTimer = setTimeout(() => { node.style.transformOrigin = ''; }, 560);
}

/* --- Slider ------------------------------------------------------------
   Los de Centro de Control: una pastilla de esquinas completas, se salta al
   punto que se toca y luego se arrastra. Sin etiqueta y sin numero: el
   icono dice que es y el relleno dice cuanto, que es exactamente lo que
   hace iOS. Vertical en el Mando, horizontal en Ahora suena. */

class Slider {
  constructor(options) {
    this.axis = options.axis;
    this.action = options.action;
    this.icons = options.icons;
    this.value = 0;
    this.dragging = false;
    this.reconcile = new Reconcile(2);
    this.queued = null;
    this.timer = null;
    this.detent = null;
    this.node = this.build(options);
  }

  build(options) {
    const node = document.createElement('div');
    node.className = 'slider pane ' + (this.axis === 'v' ? 'slider--v' : 'slider--h');
    node.setAttribute('role', 'slider');
    node.setAttribute('tabindex', '0');
    node.setAttribute('aria-label', options.label);
    node.setAttribute('aria-valuemin', '0');
    node.setAttribute('aria-valuemax', '100');

    node.innerHTML =
      '<div class="slider-fill"></div>' +
      '<svg class="slider-icon" aria-hidden="true"><use href="#i-' + this.icons[1] + '"/></svg>';

    this.fill = node.querySelector('.slider-fill');
    this.iconUse = node.querySelector('.slider-icon use');

    // El dedo no mueve el nivel al bajar, sino al MOVERSE o al soltar: asi
    // mantenerlo quieto encima sirve para ordenar el Mando (ver `Arrange`)
    // sin que el volumen salte al punto tocado. Un toque sigue fijando el
    // valor, solo que al levantar el dedo.
    node.addEventListener('pointerdown', (event) => {
      this.armed = { x: event.clientX, y: event.clientY };
      this.detent = null;
      // La caja en reposo: durante el arrastre la pastilla crece (y se estira
      // al pasarse), y medir contra la caja crecida haria que el valor y el
      // estiron se persiguieran el uno al otro.
      this.rest = node.getBoundingClientRect();
      // Si el navegador se niega, el arrastre sigue funcionando por los
      // eventos normales; lo que no puede es romper el gesto entero.
      try { node.setPointerCapture(event.pointerId); } catch { /* sin captura */ }
      event.preventDefault();
    });

    node.addEventListener('pointermove', (event) => {
      if (this.armed && !this.dragging
        && Math.hypot(event.clientX - this.armed.x, event.clientY - this.armed.y) > 3) {
        this.dragging = true;
        node.classList.add('is-dragging');
        node.classList.remove('is-holding');
      }
      if (this.dragging) this.track(event);
    });

    node.addEventListener('pointerup', (event) => {
      if (this.armed && !this.dragging) this.track(event);
      this.armed = null;
      this.rest = null;
      relax(node);
      if (!this.dragging) { this.flush(); return; }
      this.dragging = false;
      node.classList.remove('is-dragging');
      this.flush();
      Haptics.tap(11);
    });

    node.addEventListener('pointercancel', () => {
      this.armed = null;
      this.rest = null;
      relax(node);
      if (!this.dragging) return;
      this.dragging = false;
      node.classList.remove('is-dragging');
      this.flush();
    });

    // El teclado de un slider de verdad (el de React Aria): flechas de 5 en 5,
    // paginas de 20 en 20, e Inicio y Fin a los extremos.
    node.addEventListener('keydown', (event) => {
      const step = {
        ArrowLeft: -5, ArrowDown: -5, ArrowRight: 5, ArrowUp: 5,
        PageDown: -20, PageUp: 20, Home: -100, End: 100,
      }[event.key];
      if (step === undefined) return;
      event.preventDefault();
      Haptics.tap(9);
      this.commit(Math.max(0, Math.min(100, this.value + step)));
    });

    return node;
  }

  /** Suelta el gesto sin tocar el nivel: lo pide `Arrange` cuando el dedo
      quieto se convierte en "mover este mando". */
  disarm() {
    this.armed = null;
    this.rest = null;
    relax(this.node);
    if (this.dragging) {
      this.dragging = false;
      this.node.classList.remove('is-dragging');
    }
  }

  positionValue(event) {
    const box = this.rest || this.node.getBoundingClientRect();
    const ratio = this.axis === 'v'
      ? (box.bottom - event.clientY) / box.height
      : (event.clientX - box.left) / box.width;
    return Math.max(0, Math.min(100, Math.round(ratio * 100)));
  }

  track(event) {
    const next = this.positionValue(event);
    // Un golpecito cada 5 %, como el detente de los controles de iOS.
    const notch = Math.round(next / 5);
    if (notch !== this.detent) {
      this.detent = notch;
      Haptics.tap(5);
    }
    this.commit(next);
    if (this.dragging) this.overshoot(event);
  }

  /** Cuanto se ha salido el dedo de la pastilla, y por donde. */
  overshoot(event) {
    const box = this.rest || this.node.getBoundingClientRect();
    let over = 0;
    let edge = null;
    if (this.axis === 'v') {
      if (event.clientY < box.top) { over = box.top - event.clientY; edge = 'start'; }
      else if (event.clientY > box.bottom) { over = event.clientY - box.bottom; edge = 'end'; }
    } else if (event.clientX < box.left) { over = box.left - event.clientX; edge = 'start'; }
    else if (event.clientX > box.right) { over = event.clientX - box.right; edge = 'end'; }
    stretch(this.node, this.axis, over, edge);
  }

  commit(next) {
    this.paint(next);
    this.queued = next;
    if (this.timer) return;
    this.timer = setTimeout(() => this.flush(), 80);
  }

  flush() {
    clearTimeout(this.timer);
    this.timer = null;
    if (this.queued === null) return;
    const value = this.queued;
    this.queued = null;
    this.reconcile.expect(value, 900);
    send(this.action, value);
  }

  /** Lo que llega del Mac. */
  apply(value, extra) {
    if (typeof value !== 'number') return;
    if (this.dragging) return;
    if (!this.reconcile.accepts(value)) return;
    this.paint(value);
    if (extra && extra.muted !== undefined) {
      this.node.classList.toggle('is-muted', !!extra.muted);
    }
  }

  paint(value) {
    this.value = value;
    this.node.style.setProperty('--level', value + '%');
    this.node.setAttribute('aria-valuenow', String(value));
    this.node.setAttribute('aria-valuetext', value + '%');
    // Con el relleno por debajo del glifo, la tinta oscura no se veria.
    this.node.classList.toggle('is-low', value < 24);
    const step = value <= 0 ? 0 : (value < 55 ? 1 : 2);
    this.iconUse.setAttribute('href', '#i-' + this.icons[Math.min(step, this.icons.length - 1)]);
  }
}

/* --- Barra de posicion -------------------------------------------------
   Arrastrable. Antes solo se pintaba, y de ahi venia que no se pudiera
   adelantar el contenido: no habia nada que escuchara el dedo. */

class Scrub {
  constructor(node) {
    this.node = node;
    this.fill = $('scrub-fill');
    this.track$ = node.querySelector('.scrub-track');
    this.duration = 0;
    this.value = 0;
    this.dragging = false;
    this.reconcile = new Reconcile(3);

    node.addEventListener('pointerdown', (event) => {
      if (!(this.duration > 0)) return;
      this.dragging = true;
      node.classList.add('is-dragging');
      try { node.setPointerCapture(event.pointerId); } catch { /* sin captura */ }
      this.track(event);
      event.preventDefault();
    });

    node.addEventListener('pointermove', (event) => {
      if (this.dragging) this.track(event);
    });

    for (const name of ['pointerup', 'pointercancel']) {
      node.addEventListener(name, () => {
        if (!this.dragging) return;
        relax(this.track$);
        this.dragging = false;
        node.classList.remove('is-dragging');
        Haptics.tap(11);
        this.reconcile.expect(this.value, 2600);
        send('media.position', Math.round(this.value));
      });
    }

    node.addEventListener('keydown', (event) => {
      const step = { ArrowLeft: -10, ArrowRight: 10 }[event.key];
      if (step === undefined || !(this.duration > 0)) return;
      event.preventDefault();
      Haptics.tap(9);
      send('media.seek', step);
    });
  }

  track(event) {
    const box = this.node.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (event.clientX - box.left) / box.width));
    this.value = ratio * this.duration;
    this.paint();
    // La pista tambien se estira al pasarse, como la de iOS.
    const left = box.left - event.clientX;
    const right = event.clientX - box.right;
    stretch(this.track$, 'h', Math.max(0, left, right), left > 0 ? 'start' : 'end');
  }

  /** Lo que llega del Mac, o la interpolacion local entre avisos. */
  apply(position, duration) {
    this.duration = duration;
    if (this.dragging) return;
    if (!this.reconcile.accepts(position)) return;
    this.value = position;
    this.paint();
  }

  paint() {
    const ratio = this.duration > 0 ? Math.max(0, Math.min(1, this.value / this.duration)) : 0;
    this.fill.style.width = (ratio * 100) + '%';
    this.node.setAttribute('aria-valuenow', String(Math.round(ratio * 100)));
    this.node.setAttribute('aria-valuetext', clock(this.value) + ' / ' + clock(this.duration));
    $('progress-elapsed').textContent = clock(this.value);
    $('progress-left').textContent = '-' + clock(Math.max(0, this.duration - this.value));
  }
}

/* --- Catalogo de mandos -----------------------------------------------
   `gate` es el interruptor de `controls` que lo enciende. Nada aparece si
   el Mac no dice que esta disponible, y nada se inventa: cada entrada
   apunta a una accion que existe en el servidor.

   `label` es una CLAVE de traduccion, no un texto: el panel se repinta al
   cambiar de idioma y aqui no puede quedar nada en un idioma fijo. */

const SLIDERS = [
  { id: 'brightness', gate: 'brightness', label: 'deck.brightness', action: 'brightness.set', icons: ['brightness-min', 'brightness-min', 'brightness'] },
  { id: 'volume', gate: 'volume', label: 'deck.volume', action: 'volume.set', icons: ['volume-off', 'volume-low', 'volume'] },
];

const ORBS = [
  { id: 'mute', gate: 'volume', kind: 'toggle', label: 'ctl.mute', icon: 'volume-x', action: 'volume.mute' },
  // El medio circulo, no la luna: `circle.lefthalf.filled` es el glifo con
  // el que el propio sistema marca claro/oscuro. La luna es el de No
  // molestar y no se presta.
  { id: 'appearance', gate: 'appearance', kind: 'toggle', label: 'ctl.toDark', icon: 'contrast', action: 'appearance.toggle' },
  { id: 'display', gate: 'displaySleep', kind: 'fire', label: 'ctl.display', icon: 'display-off', action: 'display.sleep' },
  { id: 'lock', gate: 'lock', kind: 'fire', label: 'ctl.lock', icon: 'lock', action: 'system.lock' },
  { id: 'mission', gate: 'shortcuts', kind: 'fire', label: 'ctl.mission', icon: 'mission', action: 'shortcut.missionControl' },
  { id: 'spotlight', gate: 'shortcuts', kind: 'fire', label: 'ctl.spotlight', icon: 'search', action: 'shortcut.spotlight' },
  { id: 'screenshot', gate: 'shortcuts', kind: 'fire', label: 'ctl.screenshot', icon: 'camera', action: 'shortcut.screenshot' },
  { id: 'sleep', gate: 'sleep', kind: 'fire', label: 'ctl.sleep', icon: 'zzz', action: 'system.sleep', confirm: 'sleep' },
  { id: 'restart', gate: 'restart', kind: 'fire', label: 'ctl.restart', icon: 'restart', action: 'system.restart', danger: true, confirm: 'restart' },
  { id: 'shutdown', gate: 'shutdown', kind: 'fire', label: 'ctl.shutdown', icon: 'power', action: 'system.shutdown', danger: true, confirm: 'shutdown' },
];

const BY_ID = Object.fromEntries(ORBS.map((entry) => [entry.id, entry]));

/** Las tres hojas de confirmacion, por clave de traduccion. */
function confirmation(name) {
  return {
    title: t('ask.' + name + '.title'),
    bodyText: t('ask.' + name + '.body'),
    ok: t('ask.' + name + '.ok'),
    // Rojo solo para lo que no tiene vuelta. Poner el Mac en reposo se
    // deshace despertandolo; apagarlo y reiniciarlo, no.
    danger: !!(BY_ID[name] && BY_ID[name].danger),
  };
}

/** El orden guardado primero; lo que no mencione, detras. Asi un mando
    nuevo de una version futura aparece en vez de quedarse invisible. */
function orbOrder(controls, saved) {
  const allowed = ORBS.filter((entry) => controls[entry.gate] !== false);
  const named = (saved || []).map((id) => allowed.find((entry) => entry.id === id)).filter(Boolean);
  const rest = allowed.filter((entry) => !named.includes(entry));
  return named.concat(rest);
}

/* --- Mando -------------------------------------------------------------
   Aqui no se monta ningun contenedor: se devuelven las PIEZAS y de
   repartirlas en la cuadricula se encarga `Grid`. Cada pieza dice cuanto
   ocupa: la tira de lo que suena una fila entera (`data-span="row"`), los
   niveles una columna y dos filas (`data-h="2"`), y los circulos una celda.

   Antes esto montaba una columna flexible con una rejilla dentro, y la
   rejilla se desplazaba para pasar de pagina. Por eso asomaba la fila
   siguiente y por eso las piezas no cuadraban entre si. */

const sliders = {};
/** Las piezas del Mando y de Apps, ya montadas. Se conservan para poder
    recolocarlas al girar el movil sin volver a crearlas: un slider que se
    vuelve a montar pierde el dedo que lo estaba tocando. */
let deckItems = [];
let appItems = [];
let settingsBlocks = [];

/** Los mandos que el usuario ha quitado con el "−". */
function hiddenIds() {
  return new Set(((state.ui || {}).hidden) || []);
}

function buildDeck() {
  const controls = state.controls || {};
  const hidden = hiddenIds();
  const items = [];

  for (const entry of SLIDERS) {
    if (controls[entry.gate] === false || hidden.has(entry.id)) continue;
    // Un monitor externo no sabe decir su nivel. Antes que un slider que
    // miente, los dos pasos de subir y bajar, que si funcionan.
    const absolute = entry.id !== 'brightness' || typeof state.brightness === 'number';
    const node = absolute ? buildSlider(entry) : buildStepper(entry);
    node.dataset.item = entry.id;
    items.push(node);
  }

  for (const entry of orbOrder(controls, (state.ui || {}).deck)) {
    if (hidden.has(entry.id)) continue;
    const node = buildOrb(entry);
    node.dataset.item = entry.id;
    items.push(node);
  }

  // El orden que se dejo al arrastrar (`ui.deck`) manda sobre el de serie,
  // tambien para los niveles. Lo que no salga en la lista, detras y en su
  // orden de siempre: asi un mando nuevo aparece en vez de perderse.
  const saved = (state.ui || {}).deck || [];
  const rank = (node) => {
    const at = saved.indexOf(node.dataset.item);
    return at < 0 ? saved.length + items.indexOf(node) : at;
  };
  deckItems = items.slice().sort((a, b) => rank(a) - rank(b));
  dirty.deck = true;
  buildPlayerVolume();
}

function emptyNote(key) {
  const note = document.createElement('p');
  note.className = 'empty';
  note.textContent = t(key);
  return note;
}

/** El volumen de Ahora suena: en VERTICAL y pegado al borde derecho. Es el
    unico nivel que se toca mientras suena algo y con el movil en horizontal
    la mano derecha ya esta ahi; en horizontal, ademas, una pastilla tumbada
    se comia el ancho que necesita la portada. Vive fuera del Mando, asi que
    se monta una vez y se enciende o apaga segun los ajustes. */
function buildPlayerVolume() {
  const host = $('player-volume');
  const wanted = (state.controls || {}).volume !== false;
  host.hidden = !wanted;
  if (!wanted || sliders.playerVolume) return;
  sliders.playerVolume = new Slider({
    axis: 'v', action: 'volume.set', label: t('deck.volume'),
    icons: ['volume-off', 'volume-low', 'volume'],
  });
  host.append(sliders.playerVolume.node);
}

function buildSlider(entry) {
  const slider = new Slider({
    axis: 'v', action: entry.action, label: t(entry.label), icons: entry.icons,
  });
  // Una columna y dos filas: de ahi sale la pastilla alta de Centro de
  // Control, sin medir nada.
  slider.node.dataset.h = '2';
  sliders[entry.id] = slider;
  return slider.node;
}

/** Subir y bajar en una sola pastilla partida, para el brillo sin nivel. */
function buildStepper(entry) {
  const node = document.createElement('div');
  node.className = 'stepper pane';
  node.dataset.h = '2';
  node.setAttribute('role', 'group');
  node.setAttribute('aria-label', t(entry.label));
  node.innerHTML =
    '<button class="stepper-half" type="button" data-action="brightness.up" data-fire="1" aria-label="' + t('deck.brightnessUp') + '">' +
      '<svg aria-hidden="true"><use href="#i-brightness"/></svg></button>' +
    '<button class="stepper-half" type="button" data-action="brightness.down" data-fire="1" aria-label="' + t('deck.brightnessDown') + '">' +
      '<svg aria-hidden="true"><use href="#i-brightness-min"/></svg></button>';
  return node;
}

/** El boton circular. Icono centrado y nada de texto: es lo que se pedia y
    es lo que hace Centro de Control. El nombre vive en `aria-label`, asi
    que el lector de pantalla no se queda sin nada que decir. */
function buildOrb(entry) {
  const node = document.createElement('button');
  node.type = 'button';
  node.className = 'orb pane' + (entry.danger ? ' is-danger' : '');
  node.dataset.orb = entry.id;
  node.dataset.action = entry.action;
  if (entry.kind === 'fire') node.dataset.fire = '1';
  if (entry.confirm) node.dataset.confirm = entry.confirm;
  if (entry.kind === 'toggle') node.setAttribute('aria-pressed', 'false');
  node.setAttribute('aria-label', t(entry.label));
  node.innerHTML = '<svg class="orb-icon" aria-hidden="true"><use href="#i-' + entry.icon + '"/></svg>';
  return node;
}

/* --- Apps -------------------------------------------------------------- */

function buildApps() {
  const apps = Array.isArray(state.apps) ? state.apps : [];
  appItems = apps.map(buildApp);
  dirty.apps = true;
}

function buildApp(app) {
  const node = document.createElement('button');
  node.type = 'button';
  node.className = 'app-tile';
  node.dataset.action = 'app.open';
  node.dataset.value = app.path;
  node.setAttribute('aria-label', t('apps.open') + ' ' + app.name);

  const icon = document.createElement('span');
  icon.className = 'app-tile-icon';
  // El icono real del Mac. Si no llega, la inicial sobre el cristal: nunca
  // un glifo inventado que no se parezca a la app.
  const img = document.createElement('img');
  img.alt = '';
  img.draggable = false;
  img.loading = 'lazy';
  img.src = url('/api/appicon?p=' + encodeURIComponent(app.path));
  img.onerror = () => { img.remove(); icon.classList.add('is-letter'); icon.textContent = app.name.slice(0, 1).toUpperCase(); };
  icon.append(img);

  // Sin nombre debajo. El icono de una app del Mac ES su nombre: se
  // reconoce de un vistazo y mucho antes de que se lea nada, y una fila de
  // etiquetas de 11 px —la mitad cortadas con puntos suspensivos, como
  // "Visual Studi..."— solo añadia ruido entre iconos. El nombre entero
  // sigue estando en `aria-label`, que es de donde lo saca VoiceOver y lo
  // que ensena el movil al mantener pulsado.
  node.append(icon);
  return node;
}

/* --- Pintado ----------------------------------------------------------- */

const playing = new Reconcile();
const muted = new Reconcile();
const dark = new Reconcile();
let scrub = null;

function render(next) {
  if (!next || !Object.keys(next).length) return;
  state = next;

  backOnline();
  body.classList.add('is-live');
  body.classList.remove('is-stale', 'is-booting');
  renderLink(location.hostname, true);

  applyPreferences(state.ui || {});

  // Volver a montar una pantalla solo cuando cambia lo que la define.
  const deckStamp = stamp([
    state.controls, (state.ui || {}).deck, (state.ui || {}).hidden, state.brightness === undefined, L.code,
  ]);
  const busy = Object.values(sliders).some((slider) => slider.dragging);
  if (deckStamp !== deckSignature && !busy) {
    deckSignature = deckStamp;
    if (Edit.screen === 'deck') Edit.finish(false);
    if (Arrange.screen === 'deck') Arrange.finish(false);
    buildDeck();
    // Colocar va aqui y no en el siguiente fotograma: `renderLevels` busca
    // los botones en el DOM, y si todavia estuvieran sueltos no pintaria el
    // estado de silencio ni el de apariencia.
    //
    // Y se CONSERVA la pagina. Un aviso del Mac no es una peticion de
    // volver arriba: si estabas mirando la segunda pagina de un panel,
    // sigues ahi. A la primera se vuelve solo cuando ya no existe la que
    // mirabas, y de eso se encarga `commit`.
    placeDeck(true);
  }

  const appsStamp = stamp([(state.apps || []).map((app) => app.path), L.code]);
  if (appsStamp !== appsSignature) {
    appsSignature = appsStamp;
    if (Edit.screen === 'apps') Edit.finish(false);
    if (Arrange.screen === 'apps') Arrange.finish(false);
    buildApps();
    placeApps(true);
  }

  renderTabs();
  renderMedia();
  renderLevels();
  renderAmbience();
  if (body.dataset.screen === 'settings') renderSettings();
  relayout();
}

/* Cambiar de tema mueve decenas de variables a la vez, y las propiedades que
   las usan tienen transicion. El resultado era un cruce de 240 ms con medio
   panel en cada tema, y en algunos navegadores el color se quedaba colgado
   en el valor viejo. Se cortan las transiciones durante un fotograma. */
function reskin() {
  body.classList.add('is-reskinning');
  requestAnimationFrame(() => requestAnimationFrame(() => body.classList.remove('is-reskinning')));
}

function applyPreferences(ui) {
  const theme = ui.theme === 'auto'
    ? (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark')
    : (ui.theme || 'dark');
  if (body.dataset.theme !== theme) reskin();
  body.dataset.theme = theme;
  const glass = ui.glass || 'full';
  if (body.dataset.glass !== glass) reskin();
  body.dataset.glass = glass;
  body.dataset.anim = ui.animations === false ? 'off' : 'on';
  Haptics.enabled = ui.haptics !== false;

  // El idioma del Mac manda, pero solo si trae uno: al arrancar el panel ya
  // se ha pintado con el ultimo que se recordaba y no puede parpadear.
  if (ui.lang && ui.lang !== L.preference) relabel(ui.lang);

  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute('content', theme === 'light' ? '#EFEFF4' : '#000000');
}

/** Cambiar de idioma en caliente: el HTML fijo por `data-t` y lo montado
    desde aqui tirando las firmas, que es lo que obliga a rehacerlo. */
function relabel(preference) {
  L.use(preference);
  L.paint();
  if (body.classList.contains('is-live')) renderLink(location.hostname, true);
  $('chrome-title').textContent = t('screen.' + (body.dataset.screen || 'deck'));
  deckSignature = null;
  appsSignature = null;
  settingsSignature = null;
  buildDeck();
  placeDeck(true);
  buildApps();
  placeApps(true);
  renderMedia();
  renderLevels();
  if (body.dataset.screen === 'settings') renderSettings();
  relayout();
}

function renderTabs() {
  const controls = state.controls || {};
  // Sin panel de musica el dock no ensena la pestaña de Ahora suena, y sin
  // apps tampoco la de Apps: una pestaña que lleva a un hueco es peor que
  // una pestaña que no esta.
  const hide = {
    player: controls.music === false,
    apps: controls.apps === false || !(state.apps || []).length,
  };
  for (const [name, hidden] of Object.entries(hide)) {
    const tab = document.querySelector('.tab[data-screen="' + name + '"]');
    if (!tab) continue;
    tab.hidden = hidden;
    if (hidden && body.dataset.screen === name) show('deck');
  }
  // Una pestana que aparece o desaparece mueve a las demas.
  Dock.place(Dock.active(), false);
}

/** Que tipo de transporte toca. Un video de un navegador se mueve por
    segundos; una cancion, por pistas. */
function transportMode(track) {
  if (!track) return 'skip';
  return track.kind === 'browser' && track.canSeek ? 'seek' : 'skip';
}

/** Vuelve a lanzar la animacion `name` sobre `node` aunque ya la tuviera. */
function replay(node, name, ms) {
  if (!node) return;
  node.classList.remove(name);
  void node.offsetWidth;
  node.classList.add(name);
  clearTimeout(node.replayTimer);
  node.replayTimer = setTimeout(() => node.classList.remove(name), ms || 700);
}

/** Que suena, en una cadena: si cambia, es otra pista. */
let trackKey = null;

function renderMedia() {
  const track = state.track;
  const key = track ? [track.source, track.title, track.artist].join('|') : '';
  // El primer pintado no es un cambio: el panel acaba de abrirse.
  if (trackKey !== null && key !== trackKey) replay(document.querySelector('.player-meta'), 'is-swapping');
  trackKey = key;
  const player = document.querySelector('.player');
  // `accepts` limpia el pendiente cuando el Mac confirma o se agota la
  // espera; hasta entonces manda lo que dijimos nosotros.
  const reported = track ? !!track.playing : false;
  playing.accepts(reported);
  const isPlaying = playing.pending !== null ? playing.pending : reported;

  player.classList.toggle('is-playing', isPlaying);
  $('playpause').setAttribute('aria-label', t(isPlaying ? 'player.pause' : 'player.play'));
  $('playpause').disabled = !track;

  // Los cinco botones existen; se ensena la pareja que corresponde.
  const mode = transportMode(track);
  $('player-keys').dataset.mode = mode;
  const canSkip = !!(track && track.canSkip);
  for (const key of document.querySelectorAll('.key-skip')) key.disabled = !canSkip;
  for (const key of document.querySelectorAll('.key-seek')) key.disabled = !(track && track.canSeek);

  $('player-title').textContent = track ? track.title : t('player.nothing');
  const blocked = state.blockedBrowsers || [];
  $('player-artist').textContent = track
    ? (track.artist || track.album || '')
    : (blocked.length ? blocked[0].name + ' ' + t('player.blocked') : t('player.hint'));
  $('player-source').textContent = track ? track.source : t('player.idle');

  renderArt(track);
  renderProgress(track, isPlaying);

}

/* La previsualizacion. El Mac ya descarga y cachea la portada que diga la
   fuente —`mediaSession`, el `poster` del video, el `og:image` de la
   pagina— y la sirve desde `/api/artwork`, asi que aqui solo hay que
   ensenarla y cruzarla con un desvanecido cuando cambie.

   Si no hay ninguna, la alternativa no es un glifo gris permanente: la
   inicial de lo que suena sobre el color del ambiente, que al menos cambia
   con el contenido. */
function initialOf(track) {
  if (!track) return '';
  const source = (track.title || track.source || '').trim();
  return source ? source.slice(0, 1).toUpperCase() : '';
}

function renderArt(track) {
  const art = $('player-art');
  const img = $('player-art-img');
  // La capa de atras lleva la MISMA imagen: desenfocada, es lo que rellena
  // el cuadrado cuando la portada es apaisada. Se mueven juntas o se ve un
  // fondo que no tiene nada que ver con lo que suena.
  const back = $('player-art-back');
  $('player-art-initial').textContent = initialOf(track);
  art.classList.toggle('has-initial', !!initialOf(track));
  if (track && track.art) {
    if (img.getAttribute('src') !== track.art) {
      // Se cambia la imagen solo cuando la nueva esta cargada: si no, el
      // hueco se queda en blanco un instante a pantalla completa.
      const probe = new Image();
      probe.onload = () => {
        if (!state.track || state.track.art !== track.art) return;
        replay(art, 'is-swapping', 760);
        img.setAttribute('src', track.art);
        back.setAttribute('src', track.art);
        art.classList.add('has-art');
      };
      probe.onerror = () => art.classList.remove('has-art');
      probe.src = track.art;
    } else {
      art.classList.add('has-art');
    }
  } else {
    art.classList.remove('has-art');
    img.removeAttribute('src');
    back.removeAttribute('src');
  }
}

function renderProgress(track, isPlaying) {
  const box = $('player-progress');
  if (!track || !(track.duration > 0)) { box.hidden = true; Progress.stop(); return; }
  box.hidden = false;
  if (!scrub) scrub = new Scrub($('scrub'));
  scrub.apply(track.position, track.duration);
  Progress.follow(isPlaying);
}

/* El Mac avisa de la posicion una vez por segundo largo. Sin esto la barra
   avanzaba a saltos; con esto corre sola entre avisos y se corrige cuando
   llega el de verdad. */
const Progress = {
  timer: null,

  follow(isPlaying) {
    if (!isPlaying) return this.stop();
    if (this.timer) return;
    this.timer = setInterval(() => {
      if (!scrub || scrub.dragging || document.hidden) return;
      if (scrub.value >= scrub.duration) return;
      scrub.value = Math.min(scrub.duration, scrub.value + 0.5);
      scrub.paint();
    }, 500);
  },

  stop() {
    clearInterval(this.timer);
    this.timer = null;
  },
};

function clock(seconds) {
  const total = Math.max(0, Math.round(seconds || 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const rest = String(total % 60).padStart(2, '0');
  if (hours) return hours + ':' + String(minutes).padStart(2, '0') + ':' + rest;
  return minutes + ':' + rest;
}

function renderLevels() {
  for (const name of ['volume', 'playerVolume']) {
    if (sliders[name]) sliders[name].apply(state.volume, { muted: state.muted });
  }
  if (sliders.brightness && typeof state.brightness === 'number') {
    sliders.brightness.apply(state.brightness);
  }

  const isMuted = muted.accepts(!!state.muted) ? !!state.muted : muted.pending;
  const mute = document.querySelector('[data-orb="mute"]');
  if (mute) {
    mute.classList.toggle('is-on', !!isMuted);
    mute.setAttribute('aria-pressed', String(!!isMuted));
    mute.setAttribute('aria-label', t(isMuted ? 'ctl.unmute' : 'ctl.mute'));
    // Siempre el altavoz con la cruz: el boton dice lo que hace. El estado
    // lo dice el fondo, que se pone blanco mientras esta silenciado (`is-on`),
    // igual que el de Centro de Control.
  }

  const isDark = dark.accepts(!!state.dark) ? !!state.dark : dark.pending;
  const appearance = document.querySelector('[data-orb="appearance"]');
  if (appearance) {
    // El glifo no cambia: es el medio circulo de apariencia y se enciende
    // cuando el Mac esta en oscuro, igual que en Centro de Control. Cambiar
    // el icono a un sol decia lo que iba a pasar, no lo que pasa, y eso
    // chocaba con el de silencio, que si refleja el estado.
    appearance.classList.toggle('is-on', !!isDark);
    appearance.setAttribute('aria-pressed', String(!!isDark));
    appearance.setAttribute('aria-label', t(isDark ? 'ctl.toLight' : 'ctl.toDark'));
  }
}

/* El fondo toma la portada. Se cruza con un desvanecido porque cambiar la
   imagen de golpe da un salto de color muy visible a pantalla completa. */
function renderAmbience() {
  const art = state.track && state.track.art ? state.track.art : null;
  if (art === currentArtURL) return;
  currentArtURL = art;
  const layer = $('ambience-art');

  if (!art) {
    document.querySelector('.ambience').classList.remove('has-art');
    setTimeout(() => { if (!currentArtURL) layer.style.backgroundImage = ''; }, 640);
    return;
  }

  const probe = new Image();
  probe.onload = () => {
    if (currentArtURL !== art) return;
    layer.style.backgroundImage = 'url("' + art + '")';
    document.querySelector('.ambience').classList.add('has-art');
  };
  probe.src = art;
}

/* --- Ajustes -----------------------------------------------------------
   Lo que de verdad tiene sentido tocar desde el movil: como se ve y como
   responde. Lo demas —que mandos existen, su orden, las apps de la lista,
   las acciones de sistema, los datos del Mac— se configura en la ventana
   de ajustes de la app del Mac, que es su sitio. Tenerlo en los dos lados
   solo servia para que no coincidieran. */

function savePrefs(patch) {
  // Optimista: la apariencia tiene que cambiar en el dedo, no en el viaje.
  state.ui = Object.assign({}, state.ui, patch);
  // Tema y material cambian el panel entero: con View Transitions el nuevo
  // entra fundido sobre el viejo (la idea del Theme Toggler de Magic UI, sin
  // su circulo, que no es de Apple). Sin ellas, el corte de `reskin`.
  const look = 'theme' in patch || 'glass' in patch;
  const calm = body.dataset.anim === 'off' || matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (look && !calm && typeof document.startViewTransition === 'function') {
    document.startViewTransition(() => applyPreferences(state.ui));
  } else {
    applyPreferences(state.ui);
  }
  send('prefs.set', patch);
}

function group(title, note) {
  const box = document.createElement('section');
  box.className = 'group';
  if (title) {
    const heading = document.createElement('h2');
    heading.className = 'group-title';
    heading.textContent = title;
    box.append(heading);
  }
  const rows = document.createElement('div');
  rows.className = 'rows pane';
  box.append(rows);
  if (note) {
    const hint = document.createElement('p');
    hint.className = 'group-note';
    hint.textContent = note;
    box.append(hint);
  }
  box.rows = rows;
  return box;
}

function row(options) {
  const node = document.createElement(options.onTap ? 'button' : 'div');
  if (options.onTap) node.type = 'button';
  node.className = 'row' + (options.stack ? ' row--stack' : '') + (options.onTap ? ' is-tap' : '')
    + (options.danger ? ' is-danger' : '')
    + (options.action ? ' is-action' : '')
    + (options.disabled ? ' is-disabled' : '');

  if (options.icon) {
    const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    icon.setAttribute('class', 'row-icon');
    icon.setAttribute('aria-hidden', 'true');
    icon.innerHTML = '<use href="#i-' + options.icon + '"/>';
    node.append(icon);
  }

  const text = document.createElement('span');
  text.className = 'row-text';
  const title = document.createElement('span');
  title.className = 'row-title';
  title.textContent = options.title;
  text.append(title);
  if (options.sub) {
    const sub = document.createElement('span');
    sub.className = 'row-sub';
    sub.textContent = options.sub;
    text.append(sub);
  }
  node.append(text);

  if (options.value !== undefined) {
    const value = document.createElement('span');
    value.className = 'row-value';
    value.textContent = options.value;
    node.append(value);
  }

  if (options.control) {
    if (options.stack) {
      const shelf = document.createElement('span');
      shelf.className = 'row-shelf';
      shelf.append(options.control);
      node.append(shelf);
    } else {
      node.append(options.control);
    }
  }
  if (options.onTap) node.addEventListener('click', options.onTap);
  return node;
}

function switchControl(on, onChange) {
  const node = document.createElement('span');
  node.className = 'switch' + (on ? ' is-on' : '');
  node.setAttribute('role', 'switch');
  node.setAttribute('tabindex', '0');
  node.setAttribute('aria-checked', String(!!on));
  const flip = (event) => {
    event.stopPropagation();
    const next = !node.classList.contains('is-on');
    node.classList.toggle('is-on', next);
    node.setAttribute('aria-checked', String(next));
    onChange(next);
  };
  node.addEventListener('click', flip);
  node.addEventListener('keydown', (event) => {
    if (event.key !== ' ' && event.key !== 'Enter') return;
    event.preventDefault();
    Haptics.tap(9);
    flip(event);
  });
  return node;
}

function segmentControl(options, selected, onChange) {
  const node = document.createElement('span');
  node.className = 'segment';
  const thumb = document.createElement('span');
  thumb.className = 'segment-thumb';
  node.append(thumb);

  const buttons = options.map((option) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'segment-option';
    button.textContent = option.label;
    button.addEventListener('click', (event) => {
      event.stopPropagation();
      if (option.value === selected) return;
      // La pieza viaja ya, en el dedo; los Ajustes se rehacen despues con la
      // respuesta del Mac y la encuentran donde tiene que estar.
      selected = option.value;
      place();
      onChange(option.value);
    });
    node.append(button);
    return button;
  });

  const place = (instant) => {
    const index = Math.max(0, options.findIndex((option) => option.value === selected));
    buttons.forEach((button, i) => button.classList.toggle('is-on', i === index));
    const target = buttons[index];
    if (!target || !target.offsetWidth) return;
    // La primera vez se pone en su sitio sin viajar: antes, cada vez que los
    // Ajustes se rehacian, todas las piezas entraban deslizandose desde la
    // izquierda, como si alguien acabara de elegirlas.
    if (instant) thumb.style.transition = 'none';
    thumb.style.width = target.offsetWidth + 'px';
    thumb.style.transform = 'translateX(' + (target.offsetLeft - 2) + 'px)';
    if (instant) { void thumb.offsetWidth; thumb.style.transition = ''; }
  };
  // El indicador necesita medidas reales, que no existen hasta estar en el DOM.
  requestAnimationFrame(() => place(true));
  node.reposition = () => place(true);
  return node;
}

/** La direccion del Mac. En vertical no cabe junto a "Servidor": se corta
    con puntos suspensivos y, al tocarla, se ve entera y el titulo se va
    para dejarle la fila. Otro toque la recoge. */
function hostRow() {
  const node = row({ icon: 'wifi', title: t('set.server'), value: location.host });
  node.classList.add('row--host', 'is-tap');
  node.setAttribute('role', 'button');
  node.setAttribute('aria-expanded', 'false');
  node.addEventListener('click', () => {
    const open = node.classList.toggle('is-open');
    node.setAttribute('aria-expanded', String(open));
  });
  return node;
}

function renderSettings() {
  const ui = state.ui || {};

  const signature = stamp([ui, state.accessibility, state.blockedBrowsers, L.code]);
  if (signature === settingsSignature) return;
  settingsSignature = signature;

  const blocks = [];

  /* --- Apariencia --- */
  const look = group(t('set.look'));
  look.rows.append(row({
    icon: 'brush', title: t('set.theme'),
    control: segmentControl(
      [{ value: 'dark', label: t('set.theme.dark') },
       { value: 'light', label: t('set.theme.light') },
       { value: 'auto', label: t('set.theme.auto') }],
      ui.theme || 'dark', (value) => savePrefs({ theme: value }),
    ),
  }));
  look.rows.append(row({
    icon: 'sliders', title: t('set.material'),
    control: segmentControl(
      [{ value: 'full', label: t('set.material.full') },
       { value: 'subtle', label: t('set.material.subtle') },
       { value: 'off', label: t('set.material.off') }],
      ui.glass || 'full', (value) => savePrefs({ glass: value }),
    ),
  }));
  look.rows.append(row({
    icon: 'globe', title: t('set.lang'),
    control: segmentControl(L.options, L.preference, (value) => {
      // Primero en el dedo y luego al Mac: el cambio de idioma no puede
      // esperar al viaje de ida y vuelta.
      relabel(value);
      savePrefs({ lang: value });
    }),
  }));
  // Animaciones va con la apariencia: un grupo de una sola fila se comia
  // un titulo y un hueco, y en vertical todo tiene que caber de una vez.
  look.rows.append(row({
    icon: 'spark', title: t('set.anim'), sub: t('set.anim.sub'),
    control: switchControl(ui.animations !== false, (value) => savePrefs({ animations: value })),
  }));
  blocks.push(look);

  /* --- Conexion. Lo unico informativo que se queda, porque es lo unico
     que explica por que algo no funciona ahora mismo. --- */
  const link = group(t('set.link'));
  link.rows.append(hostRow());
  link.rows.append(row({
    icon: 'lock-line', title: t('set.access'),
    value: t(state.accessibility ? 'set.access.ok' : 'set.access.no'),
  }));
  if (!state.accessibility) {
    link.rows.append(row({
      icon: 'warning', title: t('set.access.ask'), action: true,
      sub: t('set.access.why'),
      onTap: () => send('accessibility.request'),
    }));
  }
  for (const browser of state.blockedBrowsers || []) {
    link.rows.append(row({
      icon: 'warning', title: browser.name, danger: true,
      sub: t('set.blocked.' + (browser.reason === 'permission' ? 'permission' : 'scripting')),
    }));
  }
  blocks.push(link);

  // El aviso va suelto al final, no como nota de Conexion: no habla de la
  // conexion sino de todo lo que no esta aqui.
  const more = document.createElement('p');
  more.className = 'settings-more';
  more.innerHTML = '<svg aria-hidden="true"><use href="#i-sliders"/></svg>';
  more.append(t('set.more'));
  blocks.push(more);

  settingsBlocks = blocks;
  dirty.settings = true;
  placeSettings(true);
}

/* --- Hoja de confirmacion ---------------------------------------------- */

let sheetAccept = null;

function ask(options, onConfirm) {
  $('sheet-title').textContent = options.title;
  $('sheet-body').textContent = options.bodyText;
  $('sheet-confirm').textContent = options.ok || t('sheet.ok');
  $('sheet-confirm').classList.toggle('is-danger', !!options.danger);
  $('sheet-cancel').textContent = t('sheet.cancel');
  sheetAccept = onConfirm;
  $('sheet-host').hidden = false;
  requestAnimationFrame(() => body.classList.add('is-sheeting'));
  Haptics.tap(14);
}

function closeSheet() {
  body.classList.remove('is-sheeting');
  sheetAccept = null;
  setTimeout(() => { $('sheet-host').hidden = true; }, 280);
}

$('sheet-cancel').addEventListener('click', closeSheet);
$('sheet-scrim').addEventListener('click', closeSheet);
$('sheet-confirm').addEventListener('click', () => {
  const accept = sheetAccept;
  closeSheet();
  if (accept) accept();
});

document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape') return;
  if (!$('sheet-host').hidden) closeSheet();
  else if (!$('picker-host').hidden) Picker.close();
});

/* --- El "+" de Mando y Apps --------------------------------------------
   Un boton pequeno pegado al titulo, no un hueco de la cuadricula. Abre un
   selector con lo que se puede anadir: las apps del Mac que no estan en la
   lista, o los mandos que estan apagados. Quitar sigue siendo cosa de los
   ajustes del Mac, que es donde se ve la lista entera.

   El selector es una cuadricula paginada, como los paneles: no scrollea. */

/** Todo lo que puede estar en el Mando, boton a boton, con su glifo. */
function deckCatalog() {
  return SLIDERS.map((entry) => ({ id: entry.id, gate: entry.gate, label: entry.label, icon: entry.icons[2] }))
    .concat(ORBS.map((entry) => ({ id: entry.id, gate: entry.gate, label: entry.label, icon: entry.icon })));
}

/** Volver a poner un mando. Si su interruptor del Mac estaba apagado, se
    enciende, pero los otros botones de ese interruptor (los tres atajos, o
    el volumen y el silencio) se quedan ocultos: se pidio UNO. */
function restoreDeckItem(entry) {
  const ui = state.ui = Object.assign({}, state.ui);
  const controls = state.controls = Object.assign({}, state.controls);
  const hidden = new Set(ui.hidden || []);
  hidden.delete(entry.id);
  const patch = {};
  if (controls[entry.gate] === false) {
    for (const other of deckCatalog()) {
      if (other.gate === entry.gate && other.id !== entry.id) hidden.add(other.id);
    }
    controls[entry.gate] = true;
    patch.controls = { [entry.gate]: true };
  }
  ui.hidden = [...hidden];
  patch.hidden = ui.hidden;
  send('prefs.set', patch);
}

/** Para buscar sin que importen tildes ni mayusculas: "musica" encuentra
    "Música". */
function fold(text) {
  return String(text || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
}

/** La marca de anadido, en linea y no por `<use>`: el trazo se dibuja con
    `stroke-dashoffset`, y eso hay que animarlo sobre el propio `<path>`. */
const CHECK_SVG = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m5.5 12.5 4.2 4.2 8.8-9.4" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';

/** La celda del selector: icono y nombre debajo. */
const PICK = { w: 76, h: 94, gap: 8 };

const Picker = {
  /** Todas las piezas que se pueden elegir, y las que pasan el filtro. */
  all: [],
  tiles: [],
  page: 0,
  token: 0,

  async open(mode) {
    const ticket = ++this.token;
    this.mode = mode;
    this.all = [];
    $('picker-search').value = '';
    $('picker-search-box').classList.remove('has-text');
    // Buscar solo tiene sentido con las apps del Mac, que pueden ser cien.
    // Los mandos que faltan caben siempre en una mirada.
    $('picker-search-box').hidden = mode !== 'apps';
    $('picker-title').textContent = t(mode === 'apps' ? 'add.apps.title' : 'add.deck.title');
    $('picker-host').hidden = false;
    requestAnimationFrame(() => body.classList.add('is-picking'));
    Haptics.tap(12);

    if (mode === 'deck') {
      const controls = state.controls || {};
      const hidden = hiddenIds();
      const missing = deckCatalog().filter((entry) => controls[entry.gate] === false || hidden.has(entry.id));
      this.fill(missing.map((entry) => this.controlTile(entry)), 'add.deck.none');
      return;
    }

    // Mientras el Mac busca, la cuadricula ya esta en su sitio con piezas en
    // gris (el Skeleton de shadcn y Mantine): la hoja no cambia de tamano al
    // llegar las apps.
    this.skeleton();
    let catalog = [];
    try {
      const response = await fetch(url('/api/catalog'));
      if (response.ok) catalog = (await response.json()).apps || [];
    } catch { /* sin conexion: se queda en "ninguna" */ }
    if (ticket !== this.token) return;
    const listed = new Set((state.apps || []).map((app) => app.path));
    this.fill(catalog.filter((app) => !listed.has(app.path)).map((app) => this.appTile(app)), 'add.apps.none');
  },

  close() {
    this.token += 1;
    $('picker-search').blur();
    body.classList.remove('is-picking');
    setTimeout(() => {
      $('picker-host').hidden = true;
      $('picker-body').textContent = '';
      $('picker-body').classList.remove('is-entering');
      const sheet = $('picker');
      sheet.style.transform = '';
      sheet.style.opacity = '';
      sheet.style.transition = '';
      $('picker-scrim').style.opacity = '';
      $('picker-host').style.top = '';
      $('picker-host').style.bottom = '';
    }, 300);
  },

  tile(label, art, onPick) {
    const node = document.createElement('button');
    node.type = 'button';
    node.className = 'pick';
    node.setAttribute('aria-label', label);
    const name = document.createElement('span');
    name.className = 'pick-name';
    name.textContent = label;
    node.append(art, name);
    node.addEventListener('click', () => {
      if (node.classList.contains('is-added')) return;
      node.classList.add('is-added');
      const check = document.createElement('span');
      check.className = 'pick-check';
      check.innerHTML = CHECK_SVG;
      art.append(check);
      Haptics.tap(10);
      onPick();
    });
    return node;
  },

  appTile(app) {
    const art = document.createElement('span');
    art.className = 'pick-art';
    const img = document.createElement('img');
    img.alt = '';
    img.draggable = false;
    img.loading = 'lazy';
    img.src = url('/api/appicon?p=' + encodeURIComponent(app.path));
    img.onerror = () => { img.remove(); art.classList.add('is-letter'); art.prepend(app.name.slice(0, 1).toUpperCase()); };
    art.append(img);
    return this.tile(app.name, art, () => send('apps.add', app.path));
  },

  controlTile(entry) {
    const art = document.createElement('span');
    art.className = 'pick-art is-orb pane';
    art.innerHTML = '<svg aria-hidden="true"><use href="#i-' + entry.icon + '"/></svg>';
    return this.tile(t(entry.label), art, () => restoreDeckItem(entry));
  },

  /** Un texto en lugar de la cuadricula. `keepSize` deja la hoja como esta:
      buscando, que encoja y crezca con cada letra mueve el campo bajo el
      dedo. */
  note(key, keepSize) {
    this.tiles = [];
    const host = $('picker-body');
    host.innerHTML = '';
    if (!keepSize) {
      host.closest('.picker').classList.add('is-compact');
      host.style.height = '120px';
    }
    host.append(emptyNote(key));
    $('picker-dots').textContent = '';
  },

  skeleton() {
    const { per } = this.measure();
    this.tiles = Array.from({ length: per }, () => {
      const node = document.createElement('span');
      node.className = 'pick is-skeleton';
      node.setAttribute('aria-hidden', 'true');
      node.innerHTML = '<span class="pick-art"></span><span class="pick-name"></span>';
      return node;
    });
    this.page = 0;
    this.layout();
  },

  fill(tiles, emptyKey) {
    this.all = tiles;
    if (!tiles.length) {
      if (this.mode === 'apps') $('picker-search-box').hidden = true;
      return this.note(emptyKey);
    }
    this.tiles = tiles;
    this.page = 0;
    this.layout();
    // Entrada escalonada, en orden de lectura (Animated List / Blur Fade de
    // Magic UI). Solo al llenarse: pasar de pagina ya tiene su movimiento.
    replay($('picker-body'), 'is-entering', 1000);
  },

  /** Filtra mientras se escribe. Primero lo que EMPIEZA por lo escrito y
      luego lo que lo contiene, que es lo que se espera de un buscador de
      apps: "mu" tiene que dar Música antes que Spotify Premium Music. */
  filter(query) {
    $('picker-search-box').classList.toggle('has-text', !!query);
    if (!this.all.length) return;
    const needle = fold(query);
    let tiles = this.all;
    if (needle) {
      const named = this.all.map((tile) => [tile, fold(tile.getAttribute('aria-label'))]);
      tiles = named.filter(([, name]) => name.startsWith(needle)).map(([tile]) => tile)
        .concat(named.filter(([, name]) => !name.startsWith(needle) && name.includes(needle)).map(([tile]) => tile));
    }
    if (!tiles.length) return this.note('add.apps.nomatch', true);
    this.tiles = tiles;
    this.page = 0;
    this.layout();
  },

  /** Cuantas caben, con la hoja a tope de alto. */
  measure() {
    const host = $('picker-body');
    host.closest('.picker').classList.remove('is-compact');
    host.style.height = '';
    const cols = Math.max(2, Math.floor((host.clientWidth + PICK.gap) / (PICK.w + PICK.gap)));
    const rows = Math.max(1, Math.floor((host.clientHeight + PICK.gap) / (PICK.h + PICK.gap)));
    return { host, cols, rows, per: cols * rows };
  },

  /** Monta las paginas. La celda es fija (icono + nombre) y la pagina sale
      del hueco real de la hoja. */
  layout() {
    if (!this.tiles.length || $('picker-host').hidden) return;
    const { host, cols, rows, per } = this.measure();
    const count = Math.ceil(this.tiles.length / per);
    host.textContent = '';
    for (let i = 0; i < count; i += 1) {
      const page = document.createElement('div');
      page.className = 'pick-page';
      page.style.setProperty('--cols', String(cols));
      page.style.setProperty('--rows', String(rows));
      this.tiles.slice(i * per, (i + 1) * per).forEach((tile, n) => {
        tile.style.setProperty('--i', String(n));
        page.append(tile);
      });
      host.append(page);
    }
    // Con los mandos, si todo cabe en una pagina, la hoja se recoge a lo que
    // ocupa: una hoja alta con dos iconos arriba es un hueco. Con las apps
    // no: la hoja tiene que quedarse quieta mientras se escribe.
    if (count === 1 && this.mode !== 'apps') {
      const used = Math.ceil(this.tiles.length / cols);
      host.closest('.picker').classList.add('is-compact');
      host.style.height = (used * PICK.h + (used - 1) * PICK.gap) + 'px';
    }
    this.go(Math.min(this.page, count - 1));
  },

  go(index) {
    const pages = [...$('picker-body').querySelectorAll('.pick-page')];
    if (!pages.length) return false;
    const next = Math.max(0, Math.min(index, pages.length - 1));
    const moved = next !== this.page;
    this.page = next;
    pages.forEach((page, n) => {
      page.classList.toggle('is-current', n === next);
      page.classList.toggle('is-before', n < next);
    });
    const dots = $('picker-dots');
    dots.textContent = '';
    if (pages.length > 1) {
      for (let i = 0; i < pages.length; i += 1) {
        const dot = document.createElement('span');
        dot.className = 'dot' + (i === next ? ' is-on' : '');
        dots.append(dot);
      }
    }
    return moved;
  },
};

$('chrome-add').addEventListener('click', () => Picker.open(body.dataset.screen === 'apps' ? 'apps' : 'deck'));

$('picker-search').addEventListener('input', (event) => Picker.filter(event.target.value));
$('picker-search').addEventListener('keydown', (event) => {
  // Escape borra lo escrito antes de cerrar nada (el SearchField de React
  // Aria); Intro guarda el teclado para ver la cuadricula entera.
  if (event.key === 'Escape' && event.target.value) {
    event.stopPropagation();
    event.target.value = '';
    Picker.filter('');
  } else if (event.key === 'Enter') {
    event.preventDefault();
    event.target.blur();
  }
});
$('picker-clear').addEventListener('click', () => {
  $('picker-search').value = '';
  Picker.filter('');
  $('picker-search').focus();
});

/* El teclado del movil se come media pantalla. La hoja se mide contra lo que
   queda visible, asi que la cuadricula pierde filas en vez de esconderse
   debajo de las teclas. */
if (window.visualViewport) {
  visualViewport.addEventListener('resize', () => {
    const host = $('picker-host');
    if (host.hidden) return;
    const view = visualViewport;
    host.style.top = Math.max(0, view.offsetTop) + 'px';
    host.style.bottom = Math.max(0, innerHeight - view.height - view.offsetTop) + 'px';
    Picker.layout();
  });
}

/* Cerrar arrastrando, como una hoja de iOS (el Drawer de shadcn/Vaul). Se
   coge por la cabecera o el asa; hacia abajo sigue al dedo y apaga el velo,
   hacia arriba se resiste. Se cierra si se ha bajado bastante o se ha
   soltado con impulso; si no, vuelve con muelle. */
const SheetDrag = {
  DISMISS: 110,
  FLICK: 0.55,
  drag: null,

  start(event) {
    if (!event.target.closest('.picker-head, .sheet-grabber') || event.target.closest('button, input')) return;
    const sheet = $('picker');
    this.drag = { y: event.clientY, t: performance.now(), dy: 0, v: 0, past: false };
    try { sheet.setPointerCapture(event.pointerId); } catch { /* sin captura */ }
    sheet.classList.add('is-dragging');
  },

  move(event) {
    const drag = this.drag;
    if (!drag) return;
    const dy = event.clientY - drag.y;
    const now = performance.now();
    drag.v = (dy - drag.dy) / Math.max(1, now - drag.t);
    drag.t = now;
    drag.dy = dy;
    const shown = dy > 0 ? dy : -Math.sqrt(-dy) * 2.2;
    $('picker').style.transform = 'translate3d(0, ' + shown + 'px, 0)';
    $('picker-scrim').style.opacity = String(Math.max(0.2, 1 - Math.max(0, dy) / 420));
    const past = dy > this.DISMISS;
    if (past !== drag.past) { drag.past = past; Haptics.tap(8); }
  },

  end() {
    const drag = this.drag;
    if (!drag) return;
    this.drag = null;
    const sheet = $('picker');
    sheet.classList.remove('is-dragging');
    if (drag.dy > this.DISMISS || (drag.v > this.FLICK && drag.dy > 24)) {
      sheet.style.transition = 'transform 320ms var(--ease), opacity 240ms var(--micro)';
      sheet.style.transform = 'translate3d(0, ' + (drag.dy + 280) + 'px, 0)';
      sheet.style.opacity = '0';
      $('picker-scrim').style.opacity = '';
      Picker.close();
      return;
    }
    sheet.style.transition = 'transform 460ms var(--spring)';
    sheet.style.transform = '';
    $('picker-scrim').style.opacity = '';
    setTimeout(() => { if (!this.drag) sheet.style.transition = ''; }, 480);
  },
};

$('picker').addEventListener('pointerdown', (event) => SheetDrag.start(event));
$('picker').addEventListener('pointermove', (event) => SheetDrag.move(event));
$('picker').addEventListener('pointerup', () => SheetDrag.end());
$('picker').addEventListener('pointercancel', () => SheetDrag.end());

/* --- El "−": quitar del panel -------------------------------------------
   Nada de quitar de un toque: un globo pequeno en la esquina de cada icono
   pide una punteria que no se tiene con el movil en la mano. Primero un
   aviso que explica el juego, luego se marcan las que sobran (el globo se
   pone rojo) y al pulsar Listo se quitan todas de golpe. Cancelar no
   quita nada. */

const Edit = {
  screen: null,
  marked: new Set(),

  ask() {
    const screen = body.dataset.screen === 'apps' ? 'apps' : 'deck';
    ask({
      title: t('edit.' + screen + '.title'),
      bodyText: t('edit.' + screen + '.body'),
      ok: t('edit.continue'),
    }, () => this.start(screen));
  },

  items() {
    return this.screen === 'apps' ? appItems : deckItems;
  },

  start(screen) {
    this.screen = screen;
    this.marked = new Set();
    body.dataset.editing = screen;
    for (const item of (screen === 'apps' ? appItems : deckItems)) {
      const mark = document.createElement('span');
      mark.className = 'edit-mark';
      mark.innerHTML = '<span class="edit-bubble"><svg aria-hidden="true"><use href="#i-minus"/></svg></span>';
      // El globo se come el toque entero: ni se abre la app ni se mueve el
      // slider que haya debajo.
      mark.addEventListener('pointerdown', (event) => event.stopPropagation());
      mark.addEventListener('click', (event) => {
        event.stopPropagation();
        const key = this.keyOf(item);
        const on = !this.marked.has(key);
        if (on) this.marked.add(key); else this.marked.delete(key);
        item.classList.toggle('is-marked', on);
        Haptics.tap(10);
      });
      item.append(mark);
    }
  },

  keyOf(item) {
    return this.screen === 'apps' ? item.dataset.value : item.dataset.item;
  },

  finish(apply) {
    if (!this.screen) return;
    const screen = this.screen;
    const marked = [...this.marked];
    this.screen = null;
    this.marked = new Set();
    delete body.dataset.editing;
    for (const item of (screen === 'apps' ? appItems : deckItems)) {
      item.classList.remove('is-marked');
      const mark = item.querySelector(':scope > .edit-mark');
      if (mark) mark.remove();
    }
    if (!apply || !marked.length) return;
    if (screen === 'apps') {
      send('apps.remove', marked);
    } else {
      const ui = state.ui = Object.assign({}, state.ui);
      ui.hidden = [...new Set((ui.hidden || []).concat(marked))];
      send('prefs.set', { hidden: ui.hidden });
    }
  },
};

$('chrome-remove').addEventListener('click', () => Edit.ask());
$('chrome-done').addEventListener('click', () => {
  if (Arrange.screen) Arrange.finish(true);
  else Edit.finish(true);
});
$('chrome-cancel').addEventListener('click', () => Edit.finish(false));

/* --- Ordenar: mantener pulsado y arrastrar ------------------------------
   Como la pantalla de inicio del iPhone. Se mantiene pulsado un icono (o un
   mando) medio segundo y todo el panel entra en modo ordenar: las piezas
   tiemblan y la que tienes debajo del dedo se levanta y lo sigue. Las demas
   se apartan para dejarle sitio. Ya en el modo, basta con arrastrar
   cualquiera, sin volver a esperar. Llevarla al borde de arriba o de abajo
   pasa de pagina. "Listo" guarda el orden en el Mac.

   Tres decisiones que explican el codigo:

   1. La pieza que se arrastra NO se mueve en el DOM mientras el dedo esta
      encima. En iOS, si el nodo que recibio el toque se descuelga, los
      eventos siguientes dejan de llegar a `window` y el arrastre se queda
      colgado. Asi que lo que sigue al dedo es un CLON (`ghost`), la pieza
      original se queda quieta e invisible donde estaba, y su sitio en la
      cuadricula lo ocupa un hueco vacio (`slot`) que es lo que se reordena.

   2. Recolocar no reconstruye las paginas: solo cambia `grid-area` y, si
      una pieza cambia de pagina, la cuelga de la otra. Lo que estaba ya en
      su pagina no se toca. Las piezas que se mueven lo hacen con FLIP sobre
      la propiedad `translate`, que no pisa el `rotate` del temblor ni el
      `transform` de la pulsacion.

   3. El orden se guarda al salir del modo, no en cada movimiento: el aviso
      del Mac que viene detras de cada guardado reconstruiria el panel con
      la pieza a medio arrastrar. */

const HOLD_MS = 480;
const HOLD_SLOP = 9;
const DRAG_SLOP = 6;
const EDGE = 40;
const EDGE_WAIT = 560;

const Arrange = {
  screen: null,
  hold: null,
  drag: null,
  // Hasta cuando ignorar el gesto de deslizar: el dedo que acaba de soltar
  // una pieza no tiene que cambiar de pagina ni de pantalla.
  quietUntil: 0,
  // El toque que acaba de levantar una pieza no debe abrir la app.
  swallowClick: false,

  itemsOf(screen) { return screen === 'apps' ? appItems : deckItems; },

  itemFrom(target) {
    const item = target.closest('.page--grid > *');
    if (!item || item.classList.contains('arrange-slot')) return null;
    const screen = item.closest('.screen');
    const name = screen && screen.dataset.screen;
    return name === 'apps' || name === 'deck' ? { item, name } : null;
  },

  /* --- Entrar y salir --- */

  start(name) {
    this.screen = name;
    this.list = this.itemsOf(name).slice();
    body.dataset.arranging = name;
    // Cada pieza tiembla a su ritmo: todas a la vez se leen como un bloque
    // que vibra, no como iconos sueltos.
    this.list.forEach((item, i) => {
      item.style.setProperty('--jiggle-delay', (-(i * 97) % 300) + 'ms');
      item.style.setProperty('--jiggle-speed', (250 + (i * 37) % 70) + 'ms');
    });
    for (const slider of Object.values(sliders)) slider.disarm();
    Haptics.tap(14);
  },

  finish(save) {
    if (!this.screen) return;
    if (this.drag) this.drop();
    const name = this.screen;
    const order = this.list;
    this.screen = null;
    this.list = null;
    delete body.dataset.arranging;
    for (const item of order) {
      item.style.removeProperty('--jiggle-delay');
      item.style.removeProperty('--jiggle-speed');
    }
    if (name === 'apps') appItems = order; else deckItems = order;
    dirty[name] = true;
    if (name === 'apps') placeApps(true); else placeDeck(true);
    if (!save) return;

    if (name === 'apps') {
      const paths = order.map((item) => item.dataset.value);
      // Se adelanta en local para que la respuesta del Mac traiga ya el
      // mismo orden y no reconstruya nada.
      const byPath = Object.fromEntries((state.apps || []).map((app) => [app.path, app]));
      state.apps = paths.map((path) => byPath[path]).filter(Boolean);
      appsSignature = stamp([paths, L.code]);
      send('apps.reorder', paths);
    } else {
      const ids = order.map((item) => item.dataset.item);
      state.ui = Object.assign({}, state.ui, { deck: ids });
      deckSignature = null;
      send('prefs.set', { deck: ids });
    }
  },

  /* --- El arrastre --- */

  lift(item, event) {
    const name = this.screen;
    const room = roomOf(name);
    const rect = item.getBoundingClientRect();
    const ghost = item.cloneNode(true);
    ghost.classList.remove('is-press', 'is-dragging', 'did-fire');
    ghost.classList.add('arrange-ghost');
    ghost.removeAttribute('id');
    // El clon vive fuera de la pagina y pierde sus medidas: se las lleva.
    const page = item.closest('.page');
    for (const prop of ['--cell', '--cell-h', '--gap']) {
      ghost.style.setProperty(prop, page.style.getPropertyValue(prop));
    }
    Object.assign(ghost.style, {
      left: rect.left + 'px', top: rect.top + 'px',
      width: rect.width + 'px', height: rect.height + 'px',
    });
    body.append(ghost);
    requestAnimationFrame(() => ghost.classList.add('is-up'));

    const slot = document.createElement('div');
    slot.className = 'arrange-slot';
    if (item.dataset.h) slot.dataset.h = item.dataset.h;
    if (item.dataset.w) slot.dataset.w = item.dataset.w;
    slot.style.gridArea = item.style.gridArea;
    page.append(slot);

    this.list[this.list.indexOf(item)] = slot;
    item.classList.add('is-lifted');
    // El dedo ya es de la pieza: el gesto de deslizar no cuenta.
    if (swipe) swipe.blocked = true;

    this.drag = {
      item, ghost, slot, room,
      dx: event.clientX - rect.left,
      dy: event.clientY - rect.top,
      edge: null,
    };
    Haptics.tap(12);
  },

  move(event) {
    const drag = this.drag;
    drag.ghost.style.translate = (event.clientX - drag.dx - parseFloat(drag.ghost.style.left)) + 'px '
      + (event.clientY - drag.dy - parseFloat(drag.ghost.style.top)) + 'px';

    // Al borde de arriba o de abajo: la pagina de al lado, tras un momento.
    const view = drag.room.screen.querySelector('.view').getBoundingClientRect();
    const dir = event.clientY < view.top + EDGE ? -1 : (event.clientY > view.bottom - EDGE ? 1 : 0);
    if (dir !== (drag.edge && drag.edge.dir)) {
      clearTimeout(drag.edge && drag.edge.timer);
      drag.edge = dir ? { dir, timer: setTimeout(() => this.turn(dir), EDGE_WAIT) } : null;
    }
    if (dir) return;

    // La casilla bajo el dedo se saca de la GEOMETRIA de la cuadricula, no
    // de lo que se ve: las piezas que se estan apartando pasan por debajo
    // del dedo a mitad de animacion y, si contaran, el reparto oscilaria.
    const page = drag.room.pages.querySelector('.page.is-current');
    const m = drag.room.pages.metrics;
    if (!page || !m) return;
    const box = page.getBoundingClientRect();
    const rows = Number(page.style.getPropertyValue('--rows')) || m.rows;
    const gridW = m.cols * m.cell + (m.cols - 1) * m.gap;
    const gridH = rows * m.cellH + (rows - 1) * m.gap;
    const fx = (event.clientX - (box.left + (box.width - gridW) / 2)) / (m.cell + m.gap);
    const fy = (event.clientY - (box.top + (box.height - gridH) / 2)) / (m.cellH + m.gap);
    const col = Math.floor(fx);
    const row = Math.floor(fy);
    if (col < 0 || col >= m.cols || row < 0) return;
    // Solo en el centro de la casilla: en el borde, el reparto oscilaria.
    const inner = (f, size, step) => Math.abs((f - Math.floor(f)) * step - size / 2) < size * 0.36;
    if (!inner(fx, m.cell, m.cell + m.gap)) return;

    const here = this.list.find((item) => item.parentNode === page && item.area
      && col >= item.area.c && col < item.area.c + item.area.w
      && row >= item.area.r && row < item.area.r + item.area.h);
    if (here) {
      if (here === drag.slot) return;
      // Una pieza de dos filas se cuenta entera; una de una, solo su centro.
      if (here.area.h === 1 && !inner(fy, m.cellH, m.cellH + m.gap)) return;
      this.place(this.list.indexOf(here));
      return;
    }
    // Una casilla libre de la ultima pagina: al final.
    const pages = [...drag.room.pages.querySelectorAll(':scope > .page')];
    if (page === pages[pages.length - 1] && row < Math.max(rows, m.rows)) this.place(this.list.length - 1);
  },

  place(to) {
    const from = this.list.indexOf(this.drag.slot);
    if (to < 0 || to === from) return;
    this.list.splice(from, 1);
    this.list.splice(to, 0, this.drag.slot);
    this.layout();
    Haptics.tap(7);
  },

  turn(dir) {
    const drag = this.drag;
    if (!drag) return;
    drag.edge = null;
    if (turnPage(drag.room.screen, dir)) {
      // Sigue esperando en el borde: si el dedo no se mueve, otra pagina.
      drag.edge = { dir, timer: setTimeout(() => this.turn(dir), EDGE_WAIT * 1.6) };
    }
  },

  /** Recoloca las piezas segun `list` sin rehacer las paginas. */
  layout() {
    const room = this.drag ? this.drag.room : roomOf(this.screen);
    const m = room.pages.metrics;
    if (!m) return;
    const current = room.pages.querySelector('.page.is-current');
    const before = new Map();
    for (const item of this.list) {
      if (item.parentNode === current) before.set(item, item.getBoundingClientRect());
    }

    const chunks = paginate(this.list, m.cols, m.rows);
    let pages = [...room.pages.querySelectorAll(':scope > .page')];
    while (pages.length < chunks.length) {
      const page = newPage('grid');
      for (const prop of ['--cols', '--cell', '--cell-h', '--gap']) {
        page.style.setProperty(prop, pages[0].style.getPropertyValue(prop));
      }
      room.pages.append(page);
      pages.push(page);
    }
    chunks.forEach((chunk, i) => {
      const page = pages[i];
      page.style.setProperty('--rows', String(chunks.length > 1 ? m.rows : chunk.used));
      for (const item of chunk.items) if (item.parentNode !== page) page.append(item);
    });
    showPage(room.screen, room.screen.pageIndex || 0);

    // FLIP: cada pieza que sigue en la pagina a la vista sale de donde
    // estaba y se desliza a su sitio nuevo.
    for (const [item, old] of before) {
      if (item.parentNode !== current || item === (this.drag && this.drag.slot)) continue;
      const now = item.getBoundingClientRect();
      const dx = old.left - now.left;
      const dy = old.top - now.top;
      if (!dx && !dy) continue;
      item.style.transition = 'none';
      item.style.translate = dx + 'px ' + dy + 'px';
      void item.offsetWidth;
      item.style.transition = 'translate 320ms var(--ease)';
      item.style.translate = '0px 0px';
      clearTimeout(item.flipTimer);
      item.flipTimer = setTimeout(() => { item.style.transition = ''; item.style.translate = ''; }, 360);
    }
  },

  drop() {
    const drag = this.drag;
    if (!drag) return;
    this.drag = null;
    clearTimeout(drag.edge && drag.edge.timer);

    // La pieza vuelve a su sitio: el que ocupa el hueco.
    const at = this.list.indexOf(drag.slot);
    this.list[at] = drag.item;
    drag.item.style.gridArea = drag.slot.style.gridArea;
    if (drag.item.parentNode !== drag.slot.parentNode) drag.slot.parentNode.append(drag.item);
    drag.slot.remove();
    drag.item.classList.remove('is-lifted');

    // El clon aterriza sobre ella y desaparece.
    const target = drag.item.getBoundingClientRect();
    const ghost = drag.ghost;
    ghost.classList.add('is-dropping');
    ghost.classList.remove('is-up');
    ghost.style.translate = (target.left - parseFloat(ghost.style.left)) + 'px '
      + (target.top - parseFloat(ghost.style.top)) + 'px';
    drag.item.classList.add('is-landing');
    setTimeout(() => { ghost.remove(); drag.item.classList.remove('is-landing'); }, 260);
    this.quietUntil = performance.now() + 450;
    Haptics.tap(10);
  },
};

/* El gesto. Va en captura sobre los paneles: en modo ordenar se queda el
   toque entero (ni se abre la app ni se mueve el slider de debajo); fuera
   de el solo mira, por si el dedo se queda quieto lo bastante. */
$('screens').addEventListener('pointerdown', (event) => {
  if (body.dataset.editing || !event.isPrimary) return;
  const hit = Arrange.itemFrom(event.target);

  if (Arrange.screen) {
    if (!hit || hit.name !== Arrange.screen) return;
    event.stopPropagation();
    event.preventDefault();
    Arrange.hold = { x: event.clientX, y: event.clientY, item: hit.item, armed: true };
    return;
  }

  if (!hit) return;
  // La pieza se hunde mientras se mantiene: dice que algo va a pasar.
  hit.item.classList.add('is-holding');
  Arrange.hold = {
    x: event.clientX, y: event.clientY, item: hit.item, armed: false,
    timer: setTimeout(() => {
      const hold = Arrange.hold;
      hit.item.classList.remove('is-holding');
      if (!hold || Object.values(sliders).some((slider) => slider.dragging)) return;
      Arrange.start(hit.name);
      Arrange.swallowClick = true;
      Arrange.lift(hold.item, { clientX: hold.x, clientY: hold.y });
    }, HOLD_MS),
  };
}, { capture: true });

addEventListener('pointermove', (event) => {
  const hold = Arrange.hold;
  if (Arrange.drag) { Arrange.move(event); return; }
  if (!hold) return;
  const far = Math.hypot(event.clientX - hold.x, event.clientY - hold.y);
  if (hold.armed && far > DRAG_SLOP) {
    Arrange.lift(hold.item, { clientX: hold.x, clientY: hold.y });
    Arrange.hold = null;
    Arrange.move(event);
  } else if (!hold.armed && far > HOLD_SLOP) {
    clearTimeout(hold.timer);
    hold.item.classList.remove('is-holding');
    Arrange.hold = null;
  }
});

for (const name of ['pointerup', 'pointercancel']) {
  addEventListener(name, () => {
    if (Arrange.hold) {
      clearTimeout(Arrange.hold.timer);
      Arrange.hold.item.classList.remove('is-holding');
    }
    Arrange.hold = null;
    if (Arrange.drag) Arrange.drop();
  });
}

// El toque que levanto una pieza no es un toque sobre ella; y en modo
// ordenar, tocar una pieza no la abre.
addEventListener('click', (event) => {
  const inGrid = event.target.closest && event.target.closest('#screens .page--grid');
  if (Arrange.swallowClick || (Arrange.screen && inGrid)) {
    Arrange.swallowClick = false;
    event.stopPropagation();
    event.preventDefault();
  }
}, { capture: true });

$('picker-done').addEventListener('click', () => Picker.close());
$('picker-scrim').addEventListener('click', () => Picker.close());
addEventListener('resize', () => Picker.layout());

// El mismo gesto que los paneles: arriba y abajo (o a los lados) pasan de
// pagina.
let pickSwipe = null;
$('picker-body').addEventListener('touchstart', (event) => {
  const touch = event.touches[0];
  pickSwipe = event.touches.length === 1 ? { x: touch.clientX, y: touch.clientY } : null;
}, { passive: true });
$('picker-body').addEventListener('touchend', (event) => {
  if (!pickSwipe) return;
  const touch = event.changedTouches[0];
  const dx = touch.clientX - pickSwipe.x;
  const dy = touch.clientY - pickSwipe.y;
  pickSwipe = null;
  const delta = Math.abs(dy) >= Math.abs(dx) ? dy : dx;
  if (Math.abs(delta) < SWIPE_Y) return;
  if (Picker.go(Picker.page + (delta < 0 ? 1 : -1))) Haptics.tap(11);
}, { passive: true });
let pickWheel = 0;
$('picker-body').addEventListener('wheel', (event) => {
  const now = performance.now();
  const delta = Math.abs(event.deltaY) >= Math.abs(event.deltaX) ? event.deltaY : event.deltaX;
  if (Math.abs(delta) < 8 || now - pickWheel < 520) return;
  if (Picker.go(Picker.page + (delta > 0 ? 1 : -1))) pickWheel = now;
}, { passive: true });

/* --- Invitacion a la pantalla de inicio --------------------------------
   En una pestana de Safari no hay manera de quitar las barras: la API de
   pantalla completa del iPhone solo vale para video. Desde el icono de la
   pantalla de inicio el panel si ocupa todo, tambien en horizontal.

   Sale UNA sola vez: la marca se guarda al ENSENARLA, no al cerrarla, para
   que volver a escanear el QR no la repita. Desde el icono no sale nunca,
   y la marca de Safari tampoco le hace falta: alli no se mira. */

const Install = {
  KEY: 'ideck.installHint',

  standalone() {
    return navigator.standalone === true
      || matchMedia('(display-mode: standalone)').matches
      || matchMedia('(display-mode: fullscreen)').matches;
  },

  platform() {
    const ua = navigator.userAgent;
    // El iPad se hace pasar por Mac; lo delata la pantalla tactil.
    if (/iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return 'ios';
    if (/Android/.test(ua)) return 'android';
    return null;
  },

  seen() {
    try { return localStorage.getItem(this.KEY) === 'seen'; } catch { return false; }
  },

  init() {
    const platform = this.platform();
    if (!platform || this.standalone() || this.seen()) return;
    try { localStorage.setItem(this.KEY, 'seen'); } catch {}

    $('install-step-1').dataset.t = 'install.step1.' + platform;
    $('install-step-2').dataset.t = 'install.step2.' + platform;
    if (platform === 'android') {
      $('install-host').querySelector('use[href="#i-share"]').setAttribute('href', '#i-menu-dots');
    }
    L.paint($('install-host'));

    $('install-host').hidden = false;
    requestAnimationFrame(() => body.classList.add('is-installing'));
    $('install-dismiss').addEventListener('click', () => this.close(), { once: true });
  },

  close() {
    body.classList.remove('is-installing');
    setTimeout(() => { $('install-host').hidden = true; }, 280);
  },
};

/* --- La cuadricula y sus paginas ---------------------------------------
   Un panel no scrollea. Nunca. Es una CUADRICULA de celdas cuadradas: caben
   tantas columnas como entren en el ancho y tantas filas como entren en el
   alto, y lo que no cabe pasa a la pagina siguiente, a la que se llega
   deslizando arriba o abajo. Las paginas no salen en el dock: no son otro
   destino, son la continuacion de este.

   Lo que habia antes no era esto. Era una tira con todo el contenido que se
   desplazaba hacia arriba para "cambiar de pagina", asi que por el acolchado
   asomaba la fila siguiente y el panel no se leia como una cuadricula
   cerrada. Ahora cada pagina es un hermano aparte: la que no toca no esta
   dibujada y no puede asomar nada de ella.

   Las medidas se calculan UNA vez por panel y viajan a CSS en variables, asi
   que el mismo numero manda en la celda, en el hueco y en el tamano del
   glifo de dentro. No hay dos cuentas que se puedan desajustar. */

/** El hueco entre celdas, por panel. No es el mismo en los dos y la razon
    es la de siempre: en el Mando lo que separa un circulo de otro es AIRE,
    y es el aire el que hace que se apunte sin mirar; en Apps el icono ya
    trae su propio margen dibujado dentro, asi que el hueco que se añade va
    encima del que ya hay y de ahi venia la sensacion de cuadricula
    desparramada. Mando respira, Apps se aprieta. */
const GAP = { deck: 12, apps: 6, settings: 10 };
/** Lo que deberia medir una celda, por panel. Las columnas salen de aqui y
    no de un numero fijo: con el movil en horizontal hay ancho de sobra y lo
    que hace falta es MAS cuadricula, no celdas mas grandes.

    Los dos paneles no miden igual a proposito. Un mando es un glifo dentro
    de un circulo y se reconoce pequeno; el icono de una app es un dibujo con
    su propio detalle y por debajo de cierto tamano deja de distinguirse de
    los demas. */
const CELL_TARGET = { deck: 80, apps: 78 };
/** Tope de celda. Sin el, en un monitor ancho salen botones de posavasos. */
const CELL_MAX = 96;
/** Por debajo de esto un circulo deja de ser comodo de apretar sin mirar. */
const CELL_MIN = 58;
/** Apps no calcula columnas: es una rejilla FIJA, como la pantalla de
    inicio. 4 x 6 en vertical y 7 x 3 en horizontal, la celda tan grande
    como deje el lado que mas aprieta y el bloque centrado. En horizontal
    son tres filas y no cuatro a proposito: con cuatro, el alto obliga a
    iconos mas pequenos que los de ahora. */
const APPS_GRID = { portrait: [4, 6], landscape: [7, 3] };

function appsMetrics(width, height, gap) {
  const [cols, rows] = width >= height ? APPS_GRID.landscape : APPS_GRID.portrait;
  const cell = Math.floor(Math.min(
    (width - (cols - 1) * gap) / cols,
    (height - (rows - 1) * gap) / rows,
  ));
  return { cols, rows, cell, cellH: cell, gap };
}

/** El Mando LLENA el hueco. En vez de partir de un tamano de celda y ver
    cuantas caben, se prueban todas las columnas posibles y se queda la que
    da la celda mas grande con todas las piezas en UNA pagina. Con dos
    niveles y ocho circulos, en horizontal sale 6 x 2 y en vertical 3 x 4:
    sin huecos y con los botones tan grandes como deja la pantalla.

    Si ni con la celda minima cabe todo en una pagina, se vuelve al reparto
    de siempre, con paginas. */
const DECK_MAX = 150;

function deckMetrics(items, width, height, gap) {
  const needed = items.reduce((total, item) => total + (Number(item.dataset.h) || 1), 0);
  let best = null;
  for (let cols = 2; cols <= 10; cols += 1) {
    for (let rows = Math.max(2, Math.ceil(needed / cols)); rows <= Math.ceil(needed / cols) + 1; rows += 1) {
      const cell = Math.floor(Math.min(
        (width - (cols - 1) * gap) / cols,
        (height - (rows - 1) * gap) / rows,
        DECK_MAX,
      ));
      if (cell < CELL_MIN || (best && cell <= best.cell)) continue;
      if (paginate(items, cols, rows).length !== 1) continue;
      best = { cols, rows, cell, cellH: cell, gap };
    }
  }
  return best;
}

/** Lo que separa dos grupos de Ajustes. El mismo valor que `.page--list`. */
const LIST_GAP = 26;

function panelOf(name) {
  return document.querySelector('.screen[data-screen="' + name + '"]');
}

/* Que paneles hay que volver a montar de verdad.

   Importa mas de lo que parece: `render` se llama con cada aviso del Mac, y
   mover un volumen hace que lleguen varios por segundo. Si cada uno volviera
   a colgar los nodos en sus paginas, el slider que tienes debajo del dedo
   cambiaria de padre a mitad del arrastre y perderia la captura del puntero
   —el rebote del volumen, otra vez, por la puerta de atras—. Asi que una
   colocacion que solo viene de un cambio de tamano comprueba antes si la
   cuadricula sale igual que la que ya hay, y si sale igual no toca nada. */
const dirty = { deck: true, apps: true, settings: true };

/** El hueco util de un panel. `.pages` mide justo el interior de `.view`,
    acolchado ya descontado, asi que no hay que restar nada a mano: ese era
    el sitio donde se colaba el desfase de un par de pixeles. */
function roomOf(name) {
  const screen = panelOf(name);
  const pages = screen && screen.querySelector('.pages');
  if (!pages) return null;
  return { screen, pages, width: pages.clientWidth, height: pages.clientHeight };
}

/** Cuantas columnas, cuantas filas y de que tamano es la celda.

    `needed` son las celdas que hay que colocar. Se usa para decidir si vale
    la pena encoger un poco la celda: si encogiendola un 8 % entra una fila
    mas y con eso cabe todo en una sola pagina, se encoge. Es mejor un
    circulo un pelin mas chico que mandar la mitad de los mandos a una
    segunda pagina por dos pixeles. */
function metricsFor(width, height, ratio, needed, target, gap) {
  const cols = Math.max(3, Math.min(14, Math.round((width + gap) / (target + gap))));
  const wide = Math.floor((width - (cols - 1) * gap) / cols);

  const rowsFor = (cell) => Math.max(1, Math.floor((height + gap) / (Math.round(cell * ratio) + gap)));
  const floorCell = Math.max(CELL_MIN, Math.round(Math.min(wide, CELL_MAX) * 0.78));

  let cell = Math.min(wide, CELL_MAX);
  let rows = rowsFor(cell);
  const want = Math.ceil(Math.max(1, needed || 1) / cols);

  while (rows < want) {
    const next = Math.floor(((height - rows * gap) / (rows + 1)) / ratio);
    if (next < floorCell) break;
    cell = next;
    const grown = rowsFor(cell);
    if (grown <= rows) break;
    rows = grown;
  }

  return { cols, rows, cell, cellH: Math.round(cell * ratio), gap };
}

/** Reparte las piezas en paginas de `cols x rows`. La colocacion es
    explicita —se busca el primer hueco libre leyendo por filas— y no
    automatica: con `grid-auto-flow` una pieza de dos filas deja huecos que
    luego rellena otra de mas abajo, y el orden deja de ser el que se puso. */
function paginate(items, cols, rows) {
  const pages = [];
  let page = null;

  const open = () => { page = { slots: new Array(cols * rows).fill(false), items: [], used: 0 }; pages.push(page); };
  const free = (r, c, w, h) => {
    if (c + w > cols || r + h > rows) return false;
    for (let y = r; y < r + h; y += 1) {
      for (let x = c; x < c + w; x += 1) if (page.slots[y * cols + x]) return false;
    }
    return true;
  };

  for (const item of items) {
    const w = item.dataset.span === 'row' ? cols : Math.min(cols, Number(item.dataset.w) || 1);
    const h = Math.min(rows, Number(item.dataset.h) || 1);
    if (!page) open();

    let placed = false;
    // Dos intentos: en la pagina en curso y, si no cabe, en una nueva, donde
    // cabe seguro porque la pieza ya viene recortada al tamano de la pagina.
    for (let attempt = 0; attempt < 2 && !placed; attempt += 1) {
      for (let r = 0; r < rows && !placed; r += 1) {
        for (let c = 0; c < cols && !placed; c += 1) {
          if (!free(r, c, w, h)) continue;
          for (let y = r; y < r + h; y += 1) {
            for (let x = c; x < c + w; x += 1) page.slots[y * cols + x] = true;
          }
          item.style.gridArea = (r + 1) + ' / ' + (c + 1) + ' / span ' + h + ' / span ' + w;
          item.area = { r, c, w, h };
          page.items.push(item);
          page.used = Math.max(page.used, r + h);
          placed = true;
        }
      }
      if (!placed) open();
    }
  }
  return pages;
}

function newPage(kind) {
  const node = document.createElement('div');
  node.className = 'page page--' + kind;
  return node;
}

/** Monta las paginas de un panel de cuadricula. */
function fillGrid(name, items, ratio, keep) {
  const target = CELL_TARGET[name] || 82;
  const gap = GAP[name] || 10;
  const room = roomOf(name);
  if (!room) return;
  if (!items.length) {
    if (!dirty[name] && room.pages.dataset.stamp === 'empty') return;
    dirty[name] = false;
    room.pages.dataset.stamp = 'empty';
    room.pages.textContent = '';
    const page = newPage('flow');
    page.append(emptyNote(name === 'apps' ? 'apps.empty' : 'deck.empty'));
    room.pages.append(page);
    return commit(room.screen, 1, keep);
  }

  // Sin medidas todavia (el panel aun no se ha dibujado) se monta una pagina
  // con todo dentro: antes un panel en blanco, que no se puede ni tocar.
  const sized = room.width > 80 && room.height > 80;
  // Lo que ocupan las piezas en celdas: una pastilla de nivel vale por dos.
  const needed = items.reduce((total, item) => total + (Number(item.dataset.h) || 1), 0);
  const m = sized
    ? (name === 'apps' ? appsMetrics(room.width, room.height, gap)
      : (name === 'deck' && deckMetrics(items, room.width, room.height, gap))
        || metricsFor(room.width, room.height, ratio, needed, target, gap))
    : { cols: 4, rows: items.length * 2, cell: 80, cellH: Math.round(80 * ratio), gap };

  // Misma cuadricula y mismas piezas que la vez anterior: no hay nada que
  // rehacer. Ver `dirty`.
  const mark = [m.cols, m.rows, m.cell, m.cellH, m.gap, items.length].join('/');
  if (!dirty[name] && room.pages.dataset.stamp === mark && room.pages.firstElementChild) return;
  dirty[name] = false;
  room.pages.dataset.stamp = mark;
  room.pages.metrics = m;

  const chunks = paginate(items, m.cols, m.rows);
  const built = chunks.map((chunk) => {
    const page = newPage('grid');
    // Con una sola pagina se usan solo las filas ocupadas, y `align-content`
    // la centra en el hueco. Con varias se usan todas, para que la
    // cuadricula caiga en el mismo sitio al pasar de pagina.
    const rows = chunks.length > 1 ? m.rows : chunk.used;
    page.style.setProperty('--cols', String(m.cols));
    page.style.setProperty('--rows', String(rows));
    page.style.setProperty('--cell', m.cell + 'px');
    page.style.setProperty('--cell-h', m.cellH + 'px');
    page.style.setProperty('--gap', m.gap + 'px');
    for (const item of chunk.items) page.append(item);
    return page;
  });

  room.pages.textContent = '';
  for (const page of built) room.pages.append(page);
  // El dock lateral se mide contra el bloque del Mando: empieza y acaba
  // donde empiezan y acaban los mandos, no de techo a suelo.
  if (name === 'deck') {
    const rows = chunks.length > 1 ? m.rows : chunks[0].used;
    document.documentElement.style.setProperty('--deck-block', (rows * m.cellH + (rows - 1) * m.gap) + 'px');
  }
  commit(room.screen, built.length, keep);
}

/** Monta las paginas de Ajustes, que no es una cuadricula sino una lista de
    grupos. El corte cae entre grupos: ninguno se queda partido por la
    mitad, y si uno solo es mas alto que la pagina se parte por filas, que es
    el unico sitio donde se puede cortar sin romper una frase. */
function fillList(name, blocks, keep) {
  const room = roomOf(name);
  if (!room || !blocks.length) return;

  const stamp = [room.height, blocks.length].join('/');
  if (!dirty[name] && room.pages.dataset.stamp === stamp && room.pages.firstElementChild) return;
  dirty[name] = false;
  room.pages.dataset.stamp = stamp;

  // Se miden dentro de una pagina de verdad: el ancho manda en la altura de
  // un texto que se parte en dos lineas.
  room.pages.textContent = '';
  const probe = newPage('list');
  probe.classList.add('is-current');
  for (const block of blocks) probe.append(block);
  room.pages.append(probe);

  const height = room.height;
  const pieces = height > 80 ? blocks.flatMap((block) => splitBlock(block, height)) : blocks.slice();

  const chunks = [[]];
  let used = 0;
  for (const piece of pieces) {
    const h = piece.offsetHeight;
    const add = used ? LIST_GAP + h : h;
    if (used && height > 80 && used + add > height) {
      chunks.push([piece]);
      used = h;
    } else {
      chunks[chunks.length - 1].push(piece);
      used += add;
    }
  }

  const built = chunks.map((chunk) => {
    const page = newPage('list');
    for (const piece of chunk) page.append(piece);
    return page;
  });

  room.pages.textContent = '';
  for (const page of built) room.pages.append(page);
  commit(room.screen, built.length, keep);
}

/** Un grupo mas alto que la pagina se reparte en varios, por filas. El
    titulo se queda en el primero: repetirlo en cada trozo se lee como si
    hubiera dos ajustes con el mismo nombre. */
function splitBlock(block, height) {
  const rows = block.querySelector('.rows');
  if (block.offsetHeight <= height || !rows || rows.children.length < 2) return [block];

  const out = [];
  let piece = block;
  let host = rows;
  let used = block.offsetHeight - rows.offsetHeight;
  for (const child of [...rows.children]) {
    const h = child.offsetHeight;
    if (host.children.length && used + h > height) {
      out.push(piece);
      piece = document.createElement('section');
      piece.className = 'group';
      host = document.createElement('div');
      host.className = 'rows pane';
      piece.append(host);
      block.parentNode.append(piece);
      used = 0;
    }
    host.append(child);
    used += h;
  }
  out.push(piece);
  return out;
}

/** Deja el panel en una pagina valida y pinta los puntos. */
function commit(screen, count, keep) {
  showPage(screen, keep ? Math.min(screen.pageIndex || 0, count - 1) : 0);
}

function showPage(screen, index) {
  const pages = [...screen.querySelectorAll('.page')];
  if (!pages.length) return;
  const i = Math.max(0, Math.min(index, pages.length - 1));
  screen.pageIndex = i;
  pages.forEach((page, n) => {
    page.classList.toggle('is-current', n === i);
    page.classList.toggle('is-before', n < i);
  });
  paintDots(screen, pages.length, i);
}

function paintDots(screen, count, index) {
  let dots = screen.querySelector(':scope > .dots');
  if (!dots) {
    dots = document.createElement('div');
    dots.className = 'dots';
    dots.setAttribute('aria-hidden', 'true');
    screen.append(dots);
  }
  dots.hidden = count < 2;
  if (dots.children.length !== count) {
    dots.textContent = '';
    for (let i = 0; i < count; i += 1) {
      const dot = document.createElement('span');
      dot.className = 'dot';
      dots.append(dot);
    }
  }
  [...dots.children].forEach((dot, i) => dot.classList.toggle('is-on', i === index));
}

/** `delta` +1 baja, -1 sube. Devuelve si habia sitio a donde ir. */
function turnPage(screen, delta) {
  if (!screen) return false;
  const count = screen.querySelectorAll('.page').length;
  if (count < 2) return false;
  const next = (screen.pageIndex || 0) + delta;
  if (next < 0 || next >= count) return false;
  showPage(screen, next);
  Haptics.tap(11);
  return true;
}

/* Colocar cuesta un reflow, asi que al girar el movil o cambiar el tamano de
   la ventana se junta todo en el mismo fotograma. El indice se conserva:
   cambiar un interruptor de Ajustes rehace la lista entera, y si aqui se
   volviera a cero el panel saltaria arriba justo al tocarlo. */

function placeDeck(keep) { fillGrid('deck', deckItems, 1, keep); }
/** La celda de Apps vuelve a ser CUADRADA. Era mas alta que ancha para
    dejar sitio al nombre debajo del icono; sin nombre, ese alto de mas era
    un hueco entre filas que nadie habia pedido. */
function placeApps(keep) { fillGrid('apps', appItems, 1, keep); }
function placeSettings(keep) { fillList('settings', settingsBlocks, keep); }

let measurePending = false;

function relayout() {
  if (measurePending) return;
  measurePending = true;
  requestAnimationFrame(() => {
    measurePending = false;
    placeDeck(true);
    placeApps(true);
    placeSettings(true);
    if (!Dock.scrub) Dock.place(Dock.active(), false);
  });
}

addEventListener('resize', relayout);
addEventListener('orientationchange', relayout);
addEventListener('load', relayout);

/* --- La lente del dock -------------------------------------------------
   Una sola pieza que viaja a la pestana elegida (el SelectionIndicator de
   React Aria y el FloatingIndicator de Mantine, con el estiron de la barra
   de Liquid Glass). Se mide con `offsetLeft/Top`, que no cambian con las
   transformaciones, asi que sirve igual con el dock abajo o a la izquierda.

   Ademas se puede arrastrar: con el dedo puesto en el dock, la lente lo
   sigue de pestana en pestana y al soltar se va a la que este debajo, como
   en la barra de pestanas de iOS 26. */

const Dock = {
  lens: $('dock-lens'),
  current: null,
  scrub: null,
  swallow: false,

  active() { return document.querySelector('.tab.is-active'); },

  tabs() { return [...document.querySelectorAll('.tab:not([hidden])')]; },

  /** `moving` anima el viaje; sin el, la lente aparece donde tiene que estar
      (al girar el movil o al ocultarse una pestana). */
  place(tab, moving) {
    const lens = this.lens;
    if (!tab || tab.hidden || !tab.offsetWidth) return;
    const from = this.current;
    // `render` pasa por aqui con cada aviso del Mac. Si nada se ha movido no
    // se toca: recolocar sin animar cortaria el viaje que este en curso.
    const geo = [tab.offsetWidth, tab.offsetHeight, tab.offsetLeft, tab.offsetTop].join('/');
    if (!moving && tab === from && geo === this.geo) return;
    this.geo = geo;
    if (!moving) lens.style.transition = 'none';
    lens.style.width = tab.offsetWidth + 'px';
    lens.style.height = tab.offsetHeight + 'px';
    lens.style.translate = tab.offsetLeft + 'px ' + tab.offsetTop + 'px';
    if (!moving) { void lens.offsetWidth; lens.style.transition = ''; }
    if (moving && from && from !== tab && lens.classList.contains('is-placed')) {
      lens.classList.remove('is-moving-x', 'is-moving-y');
      replay(lens, from.offsetTop !== tab.offsetTop ? 'is-moving-y' : 'is-moving-x', 520);
    }
    this.current = tab;
    if (!lens.classList.contains('is-placed')) requestAnimationFrame(() => lens.classList.add('is-placed'));
  },

  /** La pestana bajo el dedo, por geometria: el dedo puede haberse salido un
      poco del dock y tiene que seguir contando la mas cercana. */
  tabAt(x, y) {
    let best = null;
    let distance = Infinity;
    for (const tab of this.tabs()) {
      const box = tab.getBoundingClientRect();
      const d = Math.hypot(x - (box.left + box.width / 2), y - (box.top + box.height / 2));
      if (d < distance) { distance = d; best = tab; }
    }
    return best;
  },
};

$('dock').addEventListener('pointerdown', (event) => {
  const tab = event.target.closest('.tab');
  if (!tab || !event.isPrimary) return;
  Dock.scrub = { id: event.pointerId, start: tab, over: tab, x: event.clientX, y: event.clientY, moved: false };
});

$('dock').addEventListener('pointermove', (event) => {
  const scrub = Dock.scrub;
  if (!scrub || event.pointerId !== scrub.id) return;
  if (!scrub.moved) {
    if (Math.hypot(event.clientX - scrub.x, event.clientY - scrub.y) < 10) return;
    scrub.moved = true;
    // La captura se pide aqui y no al bajar el dedo: con ella puesta, un toque
    // normal ya no le llegaria a la pestana como `click`.
    try { $('dock').setPointerCapture(event.pointerId); } catch { /* sin captura */ }
    $('dock').classList.add('is-scrubbing');
    if (pressed.has(scrub.start)) release(scrub.start);
    Dock.place(scrub.over, true);
  }
  const tab = Dock.tabAt(event.clientX, event.clientY);
  if (tab && tab !== scrub.over) {
    scrub.over = tab;
    Dock.place(tab, true);
    Haptics.tap(6);
  }
});

function endDockScrub(event, commit) {
  const scrub = Dock.scrub;
  if (!scrub || event.pointerId !== scrub.id) return;
  Dock.scrub = null;
  if (!scrub.moved) return;
  $('dock').classList.remove('is-scrubbing');
  // El `click` que pueda venir detras es del gesto, no un toque nuevo.
  Dock.swallow = true;
  setTimeout(() => { Dock.swallow = false; }, 400);
  if (commit && scrub.over !== Dock.active()) show(scrub.over.dataset.screen);
  else Dock.place(Dock.active(), true);
}

$('dock').addEventListener('pointerup', (event) => endDockScrub(event, true));
$('dock').addEventListener('pointercancel', (event) => endDockScrub(event, false));
$('dock').addEventListener('click', (event) => {
  if (!Dock.swallow) return;
  Dock.swallow = false;
  event.stopPropagation();
  event.preventDefault();
}, { capture: true });

// Flechas entre pestanas, como las Tabs de React Aria: el foco y la
// pantalla van juntos.
$('dock').addEventListener('keydown', (event) => {
  const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key];
  if (!step) return;
  const tabs = Dock.tabs();
  const at = tabs.indexOf(document.activeElement.closest('.tab'));
  const next = tabs[(Math.max(0, at) + step + tabs.length) % tabs.length];
  if (!next) return;
  event.preventDefault();
  next.focus();
  show(next.dataset.screen);
});

/* --- Navegacion -------------------------------------------------------- */

const ORDER = ['deck', 'apps', 'player', 'settings'];

function show(name, options) {
  const tab = document.querySelector('.tab[data-screen="' + name + '"]');
  if (!tab || tab.hidden) return;
  if (body.dataset.screen === name) return;

  // La direccion de la que entra la pantalla sigue al dock, como las
  // paginas de CarPlay: hacia la derecha si vas a una pestaña posterior.
  const from = ORDER.indexOf(body.dataset.screen);
  const to = ORDER.indexOf(name);
  body.dataset.flow = to > from ? 'next' : 'prev';
  body.dataset.screen = name;

  document.querySelectorAll('.tab').forEach((other) => {
    const active = other === tab;
    other.classList.toggle('is-active', active);
    other.setAttribute('aria-current', active ? 'page' : 'false');
  });
  Dock.place(tab, true);
  document.querySelectorAll('.screen').forEach((screen) => {
    screen.classList.toggle('is-active', screen.dataset.screen === name);
  });
  $('chrome-title').textContent = t('screen.' + name);
  Edit.finish(false);
  Arrange.finish(true);
  $('chrome-add').hidden = name !== 'deck' && name !== 'apps';
  $('chrome-remove').hidden = $('chrome-add').hidden;

  if (name === 'settings') renderSettings();
  // Los indicadores del segmentado se midieron con la pantalla oculta.
  document.querySelectorAll('.segment').forEach((segment) => segment.reposition && segment.reposition());
  // Se entra por donde se dejo. Volver a un panel y encontrarlo en la
  // primera pagina obliga a repetir el gesto cada vez que se pasa por el
  // dock, y el sitio donde estabas es informacion que el usuario puso ahi.
  const screen = panelOf(name);
  if (screen) showPage(screen, screen.pageIndex || 0);
}

$('link').dataset.goto = 'settings';

document.querySelectorAll('.tab').forEach((tab) => {
  tab.addEventListener('click', () => show(tab.dataset.screen));
});

/* El gesto. Dos ejes y uno solo manda: arriba y abajo pasan de pagina
   dentro del panel, izquierda y derecha cambian de panel.

   El EJE SE FIJA en cuanto el dedo se mueve de verdad y ya no se suelta
   hasta que levanta, que es como se porta cualquier vista con scroll de
   iOS. Antes se decidia al final, comparando el desplazamiento total, y de
   ahi venia el salto al panel de al lado: un pulgar bajando no baja recto,
   describe un arco, y un arco de 70 px abajo con 110 px de lado se leia
   como un gesto horizontal. Deslizabas hacia abajo en Apps y aparecias en
   el Mando.

   Para romper el empate hace falta que lo horizontal gane CLARO
   (`AXIS_BIAS`): si no, el gesto es vertical, que es lo que se estaba
   intentando hacer. Y una vez fijado en vertical, aunque no haya pagina a
   la que ir, no se cambia de panel: quedarse donde estas es la respuesta
   correcta a un gesto que no lleva a ningun sitio.

   Lo que se toca sigue mandando: un gesto que empieza sobre un control es
   de ese control y no de la navegacion. */

/** Lo que tiene que moverse el dedo para que el eje quede fijado. */
const AXIS_LOCK = 14;
/** Cuanto tiene que ganar lo horizontal para que el gesto sea de cambiar
    de panel. Por debajo de esto el gesto es vertical. */
const AXIS_BIAS = 1.6;
/** Recorrido minimo para que el gesto cuente, por eje. */
const SWIPE_Y = 44;
const SWIPE_X = 62;

let swipe = null;

$('screens').addEventListener('touchstart', (event) => {
  if (event.touches.length !== 1) { swipe = null; return; }
  const touch = event.touches[0];
  swipe = {
    x: touch.clientX,
    y: touch.clientY,
    axis: null,
    blocked: !!event.target.closest('.slider, .scrub, .segment, .switch, .stepper'),
  };
}, { passive: true });

$('screens').addEventListener('touchmove', (event) => {
  if (!swipe || swipe.blocked || swipe.axis || event.touches.length !== 1) return;
  const touch = event.touches[0];
  const dx = Math.abs(touch.clientX - swipe.x);
  const dy = Math.abs(touch.clientY - swipe.y);
  if (Math.max(dx, dy) < AXIS_LOCK) return;
  swipe.axis = dx >= dy * AXIS_BIAS ? 'x' : 'y';
}, { passive: true });

for (const name of ['touchend', 'touchcancel']) {
  $('screens').addEventListener(name, (event) => {
    const gesture = swipe;
    swipe = null;
    if (Arrange.drag || performance.now() < Arrange.quietUntil) return;
    if (name === 'touchcancel' || !gesture || gesture.blocked || !gesture.axis) return;

    const touch = event.changedTouches[0];
    const dx = touch.clientX - gesture.x;
    const dy = touch.clientY - gesture.y;

    // Vertical: la pagina siguiente del panel, que es a donde va lo que no
    // cabia. Nunca cambia de panel, ni aunque no haya pagina a la que ir.
    if (gesture.axis === 'y') {
      if (Math.abs(dy) < SWIPE_Y) return;
      turnPage(document.querySelector('.screen.is-active'), dy < 0 ? 1 : -1);
      return;
    }

    if (Math.abs(dx) < SWIPE_X) return;
    const tabs = [...document.querySelectorAll('.tab:not([hidden])')];
    const index = tabs.findIndex((tab) => tab.classList.contains('is-active'));
    const target = tabs[index + (dx < 0 ? 1 : -1)];
    if (target) show(target.dataset.screen);
  }, { passive: true });
}

/* La rueda del raton hace lo mismo que el dedo. Con un freno: un trackpad
   manda decenas de avisos por gesto y sin el se pasarian cinco paginas de
   una pasada. */
let wheelRest = 0;

$('screens').addEventListener('wheel', (event) => {
  if (Math.abs(event.deltaY) < Math.abs(event.deltaX)) return;
  const now = performance.now();
  if (Math.abs(event.deltaY) < 8 || now - wheelRest < 520) return;
  if (turnPage(document.querySelector('.screen.is-active'), event.deltaY > 0 ? 1 : -1)) wheelRest = now;
}, { passive: true });

/* --- Acciones ---------------------------------------------------------- */

document.addEventListener('click', (event) => {
  const jump = event.target.closest('[data-goto]');
  if (jump) { show(jump.dataset.goto); return; }

  const target = event.target.closest('[data-action]');
  if (!target || target.disabled) return;

  const name = target.dataset.confirm;
  if (name) {
    ask(confirmation(name), () => fire(target));
    return;
  }
  fire(target);
});

function fire(target) {
  const action = target.dataset.action;
  if (target.dataset.fire) acknowledge(target);

  // Adelantarse al Mac en lo que tiene estado visible. `Reconcile` sostiene
  // la mentira hasta que el servidor confirma, y no mas.
  if (action === 'media.playpause' && state.track) {
    playing.expect(!state.track.playing, 1600);
    renderMedia();
  }
  if (action === 'volume.mute') {
    muted.expect(!state.muted, 1200);
    renderLevels();
  }
  if (action === 'appearance.toggle') {
    // Cambiar la apariencia de macOS tarda: la animacion del sistema dura
    // casi un segundo y el ajuste no se lee hasta que acaba.
    dark.expect(!state.dark, 2800);
    renderLevels();
  }
  // El salto se ve en la barra antes de que el Mac conteste; si no, el dedo
  // se queda sin acuse durante medio segundo.
  if (action === 'media.seek' && scrub && scrub.duration > 0) {
    const delta = Number(target.dataset.value) || 0;
    scrub.value = Math.max(0, Math.min(scrub.duration, scrub.value + delta));
    scrub.reconcile.expect(scrub.value, 2600);
    scrub.paint();
  }

  // Los atajos de teclado necesitan Accesibilidad en el Mac. Sin ella el Mac
  // contesta que si y no pasa nada: mejor decirlo que dejar un boton mudo.
  if (action.startsWith('shortcut.') && state.accessibility === false) {
    Island.show({ text: t('island.access'), icon: 'warning', tone: 'warn', ms: 3000 });
  }

  const value = target.dataset.value === undefined ? undefined : Number(target.dataset.value) || target.dataset.value;
  send(action, value).then((ok) => { if (ok) confirmOnIsland(action, value); });
}

/** Lo que pasa en el Mac y no se ve desde el movil. Lo demas (volumen,
    silencio, apariencia, lo que suena) ya se ve en el propio boton. */
const ISLAND_FOR = {
  'system.lock': ['island.lock', 'lock'],
  'display.sleep': ['island.display', 'display-off'],
  'system.sleep': ['island.sleep', 'zzz'],
  'system.restart': ['island.restart', 'restart'],
  'system.shutdown': ['island.shutdown', 'power'],
  'shortcut.screenshot': ['island.screenshot', 'camera'],
};

function confirmOnIsland(action, value) {
  if (action === 'app.open') {
    const app = (state.apps || []).find((entry) => entry.path === value);
    if (!app) return;
    Island.show({
      text: t('island.opening') + ' ' + app.name,
      image: url('/api/appicon?p=' + encodeURIComponent(app.path)),
    });
    return;
  }
  if (action.startsWith('shortcut.') && state.accessibility === false) return;
  const known = ISLAND_FOR[action];
  if (known) Island.show({ text: t(known[0]), icon: known[1] });
}

/* --- Reloj y ciclo de vida -------------------------------------------- */

function tick() {
  $('clock').textContent = new Date().toLocaleTimeString(L.code, { hour: '2-digit', minute: '2-digit' });
}

setInterval(tick, 15000);

matchMedia('(prefers-color-scheme: light)').addEventListener('change', () => {
  if ((state.ui || {}).theme === 'auto') applyPreferences(state.ui);
});

/* iOS suspende la conexion al irse a segundo plano y no siempre la
   recupera: al volver se mira y se rehace si hace falta. */
document.addEventListener('visibilitychange', () => {
  if (document.hidden) return;
  tick();
  pull();
  if (!events || events.readyState === EventSource.CLOSED) connect();
});

L.paint();
tick();
body.dataset.screen = 'deck';
Install.init();
pull();
connect();
