'use strict';

/* iDeck — los textos del panel.
   =======================================================================
   Un unico diccionario plano por idioma. Plano y no anidado a proposito:
   la clave que se lee en `app.js` es la misma que se busca aqui, asi que
   un texto sin traducir se ve de un golpe comparando las dos listas.

   `L.t(clave)` devuelve el texto del idioma activo, y cae al espanol si a
   un idioma nuevo le falta una entrada: antes una cadena de mas que una
   interfaz con huecos.

   Para anadir un idioma: una entrada mas en `DICT`, una opcion mas en
   `L.options` y nada mas. Nada de esto toca al Mac.
   ======================================================================= */

const DICT = {
  es: {
    /* --- Cromo y navegacion --- */
    'screen.deck': 'Mando',
    'screen.apps': 'Apps',
    'screen.player': 'Suena',
    'screen.settings': 'Ajustes',
    'link.connecting': 'Conectando',
    'link.offline': 'Sin conexión',
    'link.expired': 'Enlace caducado',

    /* --- Mando --- */
    'deck.brightness': 'Brillo',
    'deck.volume': 'Volumen',
    'deck.brightnessUp': 'Subir el brillo',
    'deck.brightnessDown': 'Bajar el brillo',
    'deck.empty': 'No hay mandos activos. Actívalos en los ajustes del Mac.',
    'ctl.mute': 'Silenciar',
    'ctl.unmute': 'Quitar el silencio',
    'ctl.toLight': 'Modo claro',
    'ctl.toDark': 'Modo oscuro',
    'ctl.display': 'Apagar la pantalla',
    'ctl.lock': 'Bloquear el Mac',
    'ctl.mission': 'Mission Control',
    'ctl.spotlight': 'Spotlight',
    'ctl.screenshot': 'Captura de pantalla',
    'ctl.sleep': 'Poner en reposo',
    'ctl.restart': 'Reiniciar',
    'ctl.shutdown': 'Apagar',

    /* --- Apps --- */
    'apps.empty': 'No hay apps en la lista. Se eligen en los ajustes del Mac.',
    'apps.open': 'Abrir',

    /* --- Lo que suena --- */
    'player.idle': 'En espera',
    'player.nothing': 'Nada suena',
    'player.hint': 'Pon algo en el Mac y aparecerá aquí',
    'player.blocked': 'no puede decir lo que suena. Mira Ajustes.',
    'player.open': 'Abrir lo que suena',
    'player.transport': 'Transporte',
    'player.play': 'Reproducir',
    'player.pause': 'Pausar',
    'player.prev': 'Canción anterior',
    'player.next': 'Canción siguiente',
    'player.back10': 'Atrás 10 segundos',
    'player.fwd10': 'Adelante 10 segundos',
    'player.scrub': 'Posición',

    /* --- Ajustes --- */
    'set.look': 'Apariencia',
    'set.theme': 'Tema',
    'set.theme.dark': 'Oscuro',
    'set.theme.light': 'Claro',
    'set.theme.auto': 'Auto',
    'set.material': 'Material',
    'set.material.full': 'Cristal',
    'set.material.subtle': 'Sutil',
    'set.material.off': 'Plano',
    'set.lang': 'Idioma',
    'set.anim': 'Animaciones',
    'set.anim.sub': 'Apágalas si el panel se nota lento.',
    'set.link': 'Conexión',
    'set.server': 'Servidor',
    'set.access': 'Accesibilidad',
    'set.access.ok': 'Concedido',
    'set.access.no': 'Falta',
    'set.access.ask': 'Conceder el permiso',
    'set.access.why': 'Hace falta para los atajos del sistema y para los controles de música de un navegador.',
    'set.more': 'Los ajustes avanzados los tienes en la app de iDeck del Mac.',
    'set.blocked.permission': 'Falta el permiso de Automatización. Concédelo en Ajustes del Sistema → Privacidad y seguridad → Automatización → iDeck.',
    'set.blocked.scripting': 'Activa Ver → Opciones para desarrolladores → Permitir JavaScript desde Eventos de Apple.',

    /* --- Hoja de confirmacion --- */
    'sheet.cancel': 'Cancelar',
    'sheet.ok': 'Continuar',

    /* --- Anadir --- */
    'add.label': 'Añadir',
    'add.apps.title': 'Añadir apps',
    'add.apps.loading': 'Buscando apps del Mac…',
    'add.apps.none': 'Ya están todas las apps del Mac.',
    'add.deck.title': 'Añadir mandos',
    'add.deck.none': 'Ya están todos los mandos.',
    'add.done': 'Listo',
    'add.shortcuts': 'Atajos',
    'edit.label': 'Quitar',
    'edit.apps.title': 'Quitar apps',
    'edit.apps.body': 'Selecciona las que quieras retirar del panel. Cuando le des a Listo, se quitarán.',
    'edit.deck.title': 'Quitar mandos',
    'edit.deck.body': 'Selecciona los que quieras retirar del panel. Cuando le des a Listo, se quitarán.',
    'edit.continue': 'Continuar',
    'edit.cancel': 'Cancelar',
    'edit.done': 'Listo',

    /* --- Pantalla de inicio --- */
    'install.title': 'Ponlo en la pantalla de inicio',
    'install.body': 'Así se abre a pantalla completa, sin barras del navegador.',
    'install.step1.ios': 'Pulsa Compartir (si no lo ves, está en ···)',
    'install.step2.ios': 'Elige «Añadir a pantalla de inicio»',
    'install.step1.android': 'Abre el menú ⋮ del navegador',
    'install.step2.android': 'Elige «Añadir a pantalla de inicio» o «Instalar»',
    'install.step3': 'Ábrelo desde el icono',
    'install.dismiss': 'Seguir en el navegador',
    'ask.sleep.title': 'Poner el Mac en reposo',
    'ask.sleep.body': 'Se cerrará la conexión con iDeck hasta que lo despiertes.',
    'ask.sleep.ok': 'Reposo',
    'ask.restart.title': 'Reiniciar el Mac',
    'ask.restart.body': 'Las apps pedirán guardar lo que tengan abierto.',
    'ask.restart.ok': 'Reiniciar',
    'ask.shutdown.title': 'Apagar el Mac',
    'ask.shutdown.body': 'iDeck dejará de responder hasta que lo vuelvas a encender.',
    'ask.shutdown.ok': 'Apagar',
  },

  en: {
    /* --- Chrome and navigation --- */
    'screen.deck': 'Controls',
    'screen.apps': 'Apps',
    'screen.player': 'Playing',
    'screen.settings': 'Settings',
    'link.connecting': 'Connecting',
    'link.offline': 'Offline',
    'link.expired': 'Link expired',

    /* --- Controls --- */
    'deck.brightness': 'Brightness',
    'deck.volume': 'Volume',
    'deck.brightnessUp': 'Brightness up',
    'deck.brightnessDown': 'Brightness down',
    'deck.empty': 'No controls enabled. Turn them on in the Mac settings.',
    'ctl.mute': 'Mute',
    'ctl.unmute': 'Unmute',
    'ctl.toLight': 'Light mode',
    'ctl.toDark': 'Dark mode',
    'ctl.display': 'Turn the display off',
    'ctl.lock': 'Lock the Mac',
    'ctl.mission': 'Mission Control',
    'ctl.spotlight': 'Spotlight',
    'ctl.screenshot': 'Screenshot',
    'ctl.sleep': 'Sleep',
    'ctl.restart': 'Restart',
    'ctl.shutdown': 'Shut down',

    /* --- Apps --- */
    'apps.empty': 'No apps on the list. Pick them in the Mac settings.',
    'apps.open': 'Open',

    /* --- Now playing --- */
    'player.idle': 'Idle',
    'player.nothing': 'Nothing playing',
    'player.hint': 'Play something on the Mac and it shows up here',
    'player.blocked': "can't report what's playing. See Settings.",
    'player.open': "Open what's playing",
    'player.transport': 'Transport',
    'player.play': 'Play',
    'player.pause': 'Pause',
    'player.prev': 'Previous track',
    'player.next': 'Next track',
    'player.back10': 'Back 10 seconds',
    'player.fwd10': 'Forward 10 seconds',
    'player.scrub': 'Position',

    /* --- Settings --- */
    'set.look': 'Appearance',
    'set.theme': 'Theme',
    'set.theme.dark': 'Dark',
    'set.theme.light': 'Light',
    'set.theme.auto': 'Auto',
    'set.material': 'Material',
    'set.material.full': 'Glass',
    'set.material.subtle': 'Subtle',
    'set.material.off': 'Flat',
    'set.lang': 'Language',
    'set.anim': 'Animations',
    'set.anim.sub': 'Turn them off if the panel feels slow.',
    'set.link': 'Connection',
    'set.server': 'Server',
    'set.access': 'Accessibility',
    'set.access.ok': 'Granted',
    'set.access.no': 'Missing',
    'set.access.ask': 'Grant the permission',
    'set.access.why': "Needed for system shortcuts and for a browser's media controls.",
    'set.more': 'Advanced settings live in the iDeck app on your Mac.',
    'set.blocked.permission': 'Automation permission missing. Grant it in System Settings → Privacy & Security → Automation → iDeck.',
    'set.blocked.scripting': 'Enable View → Developer → Allow JavaScript from Apple Events.',

    /* --- Confirmation sheet --- */
    'sheet.cancel': 'Cancel',
    'sheet.ok': 'Continue',

    /* --- Add --- */
    'add.label': 'Add',
    'add.apps.title': 'Add apps',
    'add.apps.loading': 'Looking for Mac apps…',
    'add.apps.none': 'Every Mac app is already here.',
    'add.deck.title': 'Add controls',
    'add.deck.none': 'Every control is already here.',
    'add.done': 'Done',
    'add.shortcuts': 'Shortcuts',
    'edit.label': 'Remove',
    'edit.apps.title': 'Remove apps',
    'edit.apps.body': 'Select the ones you want off the panel. They go away when you tap Done.',
    'edit.deck.title': 'Remove controls',
    'edit.deck.body': 'Select the ones you want off the panel. They go away when you tap Done.',
    'edit.continue': 'Continue',
    'edit.cancel': 'Cancel',
    'edit.done': 'Done',

    /* --- Home screen --- */
    'install.title': 'Add it to your Home Screen',
    'install.body': 'It then opens full screen, with no browser bars.',
    'install.step1.ios': 'Tap Share (under ··· if you can’t see it)',
    'install.step2.ios': 'Choose “Add to Home Screen”',
    'install.step1.android': 'Open the browser’s ⋮ menu',
    'install.step2.android': 'Choose “Add to Home screen” or “Install”',
    'install.step3': 'Open it from the icon',
    'install.dismiss': 'Keep using the browser',
    'ask.sleep.title': 'Put the Mac to sleep',
    'ask.sleep.body': "iDeck's connection closes until you wake it.",
    'ask.sleep.ok': 'Sleep',
    'ask.restart.title': 'Restart the Mac',
    'ask.restart.body': 'Apps will ask to save whatever they have open.',
    'ask.restart.ok': 'Restart',
    'ask.shutdown.title': 'Shut the Mac down',
    'ask.shutdown.body': "iDeck stops answering until you turn it back on.",
    'ask.shutdown.ok': 'Shut down',
  },
};

const L = {
  /* Lo que se ofrece en Ajustes. El nombre de cada idioma va en ese idioma,
     que es como lo hace iOS: nadie busca "Spanish" si no lee ingles. */
  options: [
    { value: 'auto', label: 'Auto' },
    { value: 'es', label: 'Español' },
    { value: 'en', label: 'English' },
  ],

  /** "auto", "es" o "en". Lo que el usuario eligio. */
  preference: 'auto',
  /** El idioma que de verdad se esta pintando: "es" o "en". */
  code: 'es',

  /** Al arrancar no hay estado del Mac todavia: el panel no puede quedarse
      en blanco ni parpadear de idioma, asi que se recuerda el ultimo. */
  boot() {
    let saved = null;
    try { saved = localStorage.getItem('ideck.lang'); } catch { /* modo privado */ }
    this.use(saved || 'auto');
  },

  use(preference) {
    const known = preference === 'auto' || DICT[preference] !== undefined;
    this.preference = known ? preference : 'auto';
    this.code = this.preference === 'auto' ? this.system() : this.preference;
    try { localStorage.setItem('ideck.lang', this.preference); } catch { /* modo privado */ }
    document.documentElement.lang = this.code;
    return this.code;
  },

  system() {
    const tags = navigator.languages || [navigator.language || 'es'];
    for (const tag of tags) {
      const code = String(tag).toLowerCase().slice(0, 2);
      if (DICT[code]) return code;
    }
    return 'en';
  },

  t(key) {
    const table = DICT[this.code] || DICT.es;
    const text = table[key];
    if (text !== undefined) return text;
    // Un idioma incompleto cae al espanol, que es el que esta entero.
    return DICT.es[key] !== undefined ? DICT.es[key] : key;
  },

  /** Rellena todo lo que lleva `data-t` en el HTML. Lo dinamico lo pinta
      `app.js` llamando a `t()` cuando monta cada pieza. */
  paint(root) {
    for (const node of (root || document).querySelectorAll('[data-t]')) {
      node.textContent = this.t(node.dataset.t);
    }
    for (const node of (root || document).querySelectorAll('[data-t-aria]')) {
      node.setAttribute('aria-label', this.t(node.dataset.tAria));
    }
  },
};

L.boot();
