#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#include <cstring>

#include "flutter/generated_plugin_registrant.h"

// ---------------------------------------------------------------------------
// Blur del compositor detrás de la ventana (mismo mecanismo que Ghostty):
//   · Wayland, protocolo NUEVO (estándar; KWin >= 6.7, Mutter 51, niri,
//     Hyprland...): ext_background_effect_v1.
//   · Wayland, protocolo LEGACY de KDE (KWin <= 6.6): org_kde_kwin_blur.
//   · X11: propiedad _KDE_NET_WM_BLUR_BEHIND_REGION (KWin/X11).
//
// El cliente Wayland está escrito a mano con las mismas tablas wl_message y
// opcodes que genera wayland-scanner, para no requerir el XML del protocolo
// en el build. En compositors sin soporte la petición se ignora: no hay
// efecto secundario.
// ---------------------------------------------------------------------------

#if defined(GDK_WINDOWING_X11)
#define FORAWN_HAVE_X11 1
#endif

#if defined(GDK_WINDOWING_WAYLAND) && defined(HAVE_WAYLAND_CLIENT)
#define FORAWN_HAVE_WAYLAND 1
#endif

#if defined(FORAWN_HAVE_WAYLAND)
#include <wayland-client.h>

// --- ext_background_effect_v1 (tablas estilo wayland-scanner) --------------
//
// Orden IMPORTANTE: los arrays de tipos van ANTES de las wl_interface y el
// slot del arg new_id apunta a la interfaz CREADA (así lo genera scanner;
// libwayland valida types[i] != NULL para new_id).

struct ext_background_effect_manager_v1;
struct ext_background_effect_surface_v1;

enum {
  EXT_BACKGROUND_EFFECT_SURFACE_V1_DESTROY = 0,
  EXT_BACKGROUND_EFFECT_SURFACE_V1_SET_BLUR_REGION = 1,
};
enum {
  EXT_BACKGROUND_EFFECT_MANAGER_V1_DESTROY = 0,
  EXT_BACKGROUND_EFFECT_MANAGER_V1_GET_BACKGROUND_EFFECT = 1,
};

// Requests de ext_background_effect_surface_v1: destroy(""), set_blur_region("o").
static const struct wl_interface* ext_bg_surface_request_types[] = {
    &wl_region_interface,
};
static const struct wl_message ext_bg_surface_requests[] = {
    {"destroy", "", nullptr},
    {"set_blur_region", "o", ext_bg_surface_request_types},
};

const struct wl_interface ext_background_effect_surface_v1_interface = {
    "ext_background_effect_surface_v1", 1,
    2, ext_bg_surface_requests,
    0, nullptr,
};

// Requests de ext_background_effect_manager_v1: destroy(""),
// get_background_effect("no") con new_id = surface effect + wl_surface.
static const struct wl_interface* ext_bg_manager_request_types[] = {
    &ext_background_effect_surface_v1_interface,  // new_id
    &wl_surface_interface,                        // surface
};
static const struct wl_message ext_bg_manager_requests[] = {
    {"destroy", "", nullptr},
    {"get_background_effect", "no", ext_bg_manager_request_types},
};
static const struct wl_message ext_bg_manager_events[] = {
    {"capabilities", "u", nullptr},
    {"error", "u", nullptr},
};

const struct wl_interface ext_background_effect_manager_v1_interface = {
    "ext_background_effect_manager_v1", 1,
    2, ext_bg_manager_requests,
    2, ext_bg_manager_events,
};

// --- org_kde_kwin_blur (legacy KDE, tablas estilo wayland-scanner) ---------

struct org_kde_kwin_blur_manager;
struct org_kde_kwin_blur;

enum {
  ORG_KDE_KWIN_BLUR_MANAGER_CREATE = 0,
};
enum {
  ORG_KDE_KWIN_BLUR_COMMIT = 0,
  ORG_KDE_KWIN_BLUR_SET_REGION = 1,
};

static const struct wl_interface* kde_blur_request_types[] = {
    &wl_region_interface,
};
static const struct wl_message kde_blur_requests[] = {
    {"commit", "", nullptr},
    {"set_region", "o", kde_blur_request_types},
};

const struct wl_interface org_kde_kwin_blur_interface = {
    "org_kde_kwin_blur", 1,
    2, kde_blur_requests,
    0, nullptr,
};

static const struct wl_interface* kde_blur_manager_request_types[] = {
    &org_kde_kwin_blur_interface,  // new_id
    &wl_surface_interface,         // surface
};
static const struct wl_message kde_blur_manager_requests[] = {
    {"create", "no", kde_blur_manager_request_types},
};

const struct wl_interface org_kde_kwin_blur_manager_interface = {
    "org_kde_kwin_blur_manager", 1,
    1, kde_blur_manager_requests,
    0, nullptr,
};

// --- Wrappers inline (idénticos a los que emite scanner) -------------------

static inline struct ext_background_effect_surface_v1*
ext_bg_manager_get_background_effect(
    struct ext_background_effect_manager_v1* mgr,
    struct wl_surface* surface) {
  struct wl_proxy* id = wl_proxy_marshal_flags(
      reinterpret_cast<struct wl_proxy*>(mgr),
      EXT_BACKGROUND_EFFECT_MANAGER_V1_GET_BACKGROUND_EFFECT,
      &ext_background_effect_surface_v1_interface,
      wl_proxy_get_version(reinterpret_cast<struct wl_proxy*>(mgr)), 0, nullptr,
      surface);
  return reinterpret_cast<struct ext_background_effect_surface_v1*>(id);
}

// Nota: el manager es destructor → WL_MARSHAL_FLAG_DESTROY destruye el proxy.
static inline void ext_bg_manager_destroy(
    struct ext_background_effect_manager_v1* mgr) {
  wl_proxy_marshal_flags(
      reinterpret_cast<struct wl_proxy*>(mgr),
      EXT_BACKGROUND_EFFECT_MANAGER_V1_DESTROY, nullptr,
      wl_proxy_get_version(reinterpret_cast<struct wl_proxy*>(mgr)),
      WL_MARSHAL_FLAG_DESTROY);
}

static inline void ext_bg_surface_set_blur_region(
    struct ext_background_effect_surface_v1* surface,
    struct wl_region* region) {
  wl_proxy_marshal_flags(
      reinterpret_cast<struct wl_proxy*>(surface),
      EXT_BACKGROUND_EFFECT_SURFACE_V1_SET_BLUR_REGION, nullptr,
      wl_proxy_get_version(reinterpret_cast<struct wl_proxy*>(surface)), 0,
      region);
}

static inline struct org_kde_kwin_blur* kde_blur_manager_create(
    struct org_kde_kwin_blur_manager* manager, struct wl_surface* surface) {
  struct wl_proxy* id = wl_proxy_marshal_flags(
      reinterpret_cast<struct wl_proxy*>(manager),
      ORG_KDE_KWIN_BLUR_MANAGER_CREATE, &org_kde_kwin_blur_interface,
      wl_proxy_get_version(reinterpret_cast<struct wl_proxy*>(manager)), 0,
      nullptr, surface);
  return reinterpret_cast<struct org_kde_kwin_blur*>(id);
}

static inline void kde_blur_set_region(struct org_kde_kwin_blur* blur,
                                       struct wl_region* region) {
  wl_proxy_marshal_flags(
      reinterpret_cast<struct wl_proxy*>(blur), ORG_KDE_KWIN_BLUR_SET_REGION,
      nullptr,
      wl_proxy_get_version(reinterpret_cast<struct wl_proxy*>(blur)), 0,
      region);
}

static inline void kde_blur_commit(struct org_kde_kwin_blur* blur) {
  wl_proxy_marshal_flags(
      reinterpret_cast<struct wl_proxy*>(blur), ORG_KDE_KWIN_BLUR_COMMIT,
      nullptr,
      wl_proxy_get_version(reinterpret_cast<struct wl_proxy*>(blur)), 0);
}

// --- Globals y listener ----------------------------------------------------

struct ForawnBlurGlobals {
  struct ext_background_effect_manager_v1* ext_mgr = nullptr;
  struct org_kde_kwin_blur_manager* kde_mgr = nullptr;
  struct wl_compositor* compositor = nullptr;
};

static void forawn_registry_global(void* data, struct wl_registry* registry,
                                   uint32_t name, const char* interface,
                                   uint32_t version) {
  auto* globals = static_cast<ForawnBlurGlobals*>(data);
  if (std::strcmp(interface, "ext_background_effect_manager_v1") == 0 &&
      globals->ext_mgr == nullptr) {
    globals->ext_mgr =
        static_cast<struct ext_background_effect_manager_v1*>(wl_registry_bind(
            registry, name, &ext_background_effect_manager_v1_interface, 1));
  } else if (std::strcmp(interface, "org_kde_kwin_blur_manager") == 0 &&
             globals->kde_mgr == nullptr) {
    globals->kde_mgr = static_cast<struct org_kde_kwin_blur_manager*>(
        wl_registry_bind(registry, name, &org_kde_kwin_blur_manager_interface,
                         1));
  } else if (std::strcmp(interface, "wl_compositor") == 0 &&
             globals->compositor == nullptr) {
    // v1 basta: wl_compositor_create_region existe desde la v1.
    globals->compositor = static_cast<struct wl_compositor*>(wl_registry_bind(
        registry, name, &wl_compositor_interface, 1));
  }
}

static void forawn_registry_global_remove(void* data,
                                          struct wl_registry* registry,
                                          uint32_t name) {
  // Sin acción: los globals que usamos no se retiran en la práctica.
}

static const struct wl_registry_listener forawn_registry_listener = {
    forawn_registry_global,
    forawn_registry_global_remove,
};

// Objetos de blur creados: se mantienen vivos mientras la ventana exista
// (el estado del efecto vive en ellos; destruirlos lo retiraría).
static struct ext_background_effect_surface_v1* g_ext_bg_surface = nullptr;
static struct org_kde_kwin_blur* g_kde_blur = nullptr;

// Región "grande" que el compositor recorta al tamaño real de la superficie
// (spec ext-background-effect-v1: "clipped by the compositor to the surface
// size"). Así el blur cubre la ventana aunque cambie de tamaño.
static constexpr int32_t kBlurRegionSize = 1 << 16;  // 65536x65536

static void forawn_blur_request_wayland(GdkWindow* gdk_window) {
  struct wl_display* wl_display = gdk_wayland_display_get_wl_display(
      gdk_window_get_display(gdk_window));
  struct wl_surface* surface = gdk_wayland_window_get_wl_surface(gdk_window);
  if (wl_display == nullptr || surface == nullptr) return;

  ForawnBlurGlobals globals;
  struct wl_registry* registry = wl_display_get_registry(wl_display);
  wl_registry_add_listener(registry, &forawn_registry_listener, &globals);
  // Roundtrip: procesa los eventos global ya encolados y llena `globals`.
  wl_display_roundtrip(wl_display);

  if (globals.ext_mgr != nullptr) {
    // Protocolo nuevo: la región inicial del efecto es VACÍA, hay que
    // setear una; se aplica en el próximo wl_surface.commit (el próximo
    // frame de GTK).
    struct ext_background_effect_surface_v1* bg =
        ext_bg_manager_get_background_effect(globals.ext_mgr, surface);
    if (bg != nullptr && globals.compositor != nullptr) {
      // Región creada vacía + wl_region_add (API actual de libwayland).
      struct wl_region* region =
          wl_compositor_create_region(globals.compositor);
      if (region != nullptr) {
        wl_region_add(region, 0, 0, kBlurRegionSize, kBlurRegionSize);
        ext_bg_surface_set_blur_region(bg, region);
        wl_region_destroy(region);
      }
      g_ext_bg_surface = bg;  // Se mantiene vivo.
    }
    ext_bg_manager_destroy(globals.ext_mgr);
  } else if (globals.kde_mgr != nullptr) {
    // Protocolo legacy de KDE: set_region(null) = toda la superficie.
    struct org_kde_kwin_blur* blur =
        kde_blur_manager_create(globals.kde_mgr, surface);
    if (blur != nullptr) {
      kde_blur_set_region(blur, nullptr);
      kde_blur_commit(blur);
      g_kde_blur = blur;  // Se mantiene vivo.
    }
  }

  wl_registry_destroy(registry);
}
#endif  // FORAWN_HAVE_WAYLAND

#if defined(FORAWN_HAVE_X11)
// X11: _KDE_NET_WM_BLUR_BEHIND_REGION con una región 1x1 en el origen (KWin
// la expande a toda la ventana; mismo patrón que otras apps GTK/Qt).
// Se usa gdk_property_change (GDK convierte glong→long para X11), así que no
// hace falta enlazar libX11 directamente.
static void forawn_blur_request_x11(GdkWindow* gdk_window) {
  const glong region[4] = {0, 0, 1, 1};
  gdk_property_change(
      gdk_window,
      gdk_atom_intern("_KDE_NET_WM_BLUR_BEHIND_REGION", FALSE),
      gdk_atom_intern("CARDINAL", FALSE),
      32, GDK_PROP_MODE_REPLACE,
      reinterpret_cast<const guchar*>(region), 4);
}
#endif  // FORAWN_HAVE_X11

static void forawn_blur_request(GtkWidget* widget) {
  GdkWindow* gdk_window = gtk_widget_get_window(widget);
  if (gdk_window == nullptr) return;
#if defined(FORAWN_HAVE_WAYLAND)
  if (GDK_IS_WAYLAND_DISPLAY(gdk_window_get_display(gdk_window))) {
    forawn_blur_request_wayland(gdk_window);
    return;
  }
#endif
#if defined(FORAWN_HAVE_X11)
  if (GDK_IS_X11_DISPLAY(gdk_window_get_display(gdk_window))) {
    forawn_blur_request_x11(gdk_window);
  }
#endif
}

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView *view)
{
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Sin header bar nativo: la app dibuja su propia barra de título
  // (unificada en los 3 SO). En Wayland GTK3 auto-crea un GtkHeaderBar con
  // título + botones para ventanas CSD decoradas; set_decorated(false) lo
  // elimina desde el runner (no depende del timing de los method channels
  // de window_manager) y el compositor no dibuja SSD ni controles.
  gtk_window_set_decorated(window, false);
  gtk_window_set_title(window, "Forawn");

  // Establecer el icono de la ventana desde el asset empaquetado
  // (data/flutter_assets/assets/icon.png) en lugar del icono por defecto.
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path != nullptr) {
    g_autofree gchar* exe_dir = g_path_get_dirname(exe_path);
    g_autofree gchar* icon_path = g_build_filename(
        exe_dir, "data", "flutter_assets", "assets", "icon.png", nullptr);
    g_autoptr(GError) icon_error = nullptr;
    GdkPixbuf* pixbuf = gdk_pixbuf_new_from_file(icon_path, &icon_error);
    if (pixbuf != nullptr) {
      GdkPixbuf* scaled = gdk_pixbuf_scale_simple(
          pixbuf, 256, 256, GDK_INTERP_BILINEAR);
      if (scaled != nullptr) {
        gtk_window_set_icon(window, scaled);
        g_object_unref(scaled);
      }
      g_object_unref(pixbuf);
    }
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color = {0.0, 0.0, 0.0, 0.0};
  // Fondo del view TRANSPARENTE: el tinte del efecto de ventana (solid /
  // transparent) lo pinta flutter_acrylic en la ventana GTK (DrawCallback
  // sobre el toplevel RGBA). Un fondo opaco aquí lo taparía y la ventana se
  // vería sólida aunque el efecto estuviera aplicado. La app pinta su propio
  // fondo (#1E1E1E en modo oscuro) desde Flutter en el primer frame, así que
  // no hay parpadeo.
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Registrar plugins ANTES de realize: flutter_acrylic configura en su
  // registro el visual RGBA + app_paintable de la ventana, y el visual solo
  // surte efecto en widgets AÚN NO realizados. (Orden del template original:
  // realize → plugins, dejaba la ventana sin RGBA = sin transparencia.)
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  // El plugin de acrylic hace gtk_widget_show(window) al registrarse; se
  // re-oculta dentro del mismo bloque síncrono (nunca llega a mapearse:
  // el main loop de GTK no iteró) para que la ventana aparezca con el
  // primer frame renderizado, como diseñó el runner.
  gtk_widget_hide(GTK_WIDGET(window));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb), self);
  gtk_widget_realize(GTK_WIDGET(view));

  // Pedir el blur al compositor con la ventana ya realizada (necesitamos su
  // wl_surface / XID). Sin soporte del compositor, la petición se ignora.
  forawn_blur_request(GTK_WIDGET(window));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  // dispose es un vfunc de GObjectClass (GApplicationClass no lo declara).
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
