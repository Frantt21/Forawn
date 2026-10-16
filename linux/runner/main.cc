#include "my_application.h"

#include <glib.h>

int main(int argc, char** argv) {
  // --- Backend gráfico: X11 (XWayland) en Wayland --------------------------
  //
  // En Wayland, GTK3 solo negocia decoraciones con el protocolo LEGACY de KDE
  // (org_kde_kwin_server_decoration; no implementa el estándar
  // xdg_decoration_manager_v1) y KWin >= 6.7 fuerza decoración server-side
  // para esos clientes: dibuja su propia titlebar y
  // gtk_window_set_decorated(false) NO tiene efecto (verificado con un probe
  // GTK3 + análisis de capturas; tampoco lo quita una regla de ventana de
  // KWin). Con el backend X11, KWin respeta los _MOTIF_WM_HINTS que manda GTK
  // y la ventana queda sin marco, dejando solo la titlebar propia de la app.
  //
  // Solo se fuerza si hay XWayland (DISPLAY definido) y el usuario no eligió
  // backend a mano: `GDK_BACKEND=wayland forawn` vuelve a Wayland nativo
  // (con la titlebar de KWin) para poder comparar.
  if (g_getenv("DISPLAY") != nullptr && g_getenv("GDK_BACKEND") == nullptr) {
    g_setenv("GDK_BACKEND", "x11", TRUE);
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
