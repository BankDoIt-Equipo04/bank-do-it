# BANKDOIT en Flutter

## Iniciar la demo

Desde `backend`, con las dependencias de `requirements.txt` instaladas, ejecuta `python -m app.datos_demo` para preparar o actualizar la base local. Después ejecuta `python -m uvicorn app.main:app`. El servidor queda en `http://127.0.0.1:8000`.

Desde `mobile`, ejecuta `flutter pub get` y elige un destino.

- **Web:** `flutter run -d chrome`. La API admite los orígenes locales de desarrollo.
- **Escritorio Windows:** `flutter run -d windows`.
- **Android por USB:** con depuración autorizada, ejecuta `adb reverse tcp:8000 tcp:8000` y después `flutter run -d ID` con el identificador que muestra `flutter devices`. El servidor permanece en la computadora.
- **Emulador Android:** `flutter run -d ID --dart-define=API_URL=http://10.0.2.2:8000`.

La pantalla inicial permite registrar un alias, una contraseña y un saldo simulado. Inicia sesión para abrir tu bankroll. Puedes salir con el botón de cerrar sesión. Los borradores quedan asociados a la cuenta y se recuperan al volver a ingresar. La sesión se mantiene en memoria mientras la app está abierta. Se requiere la API de cuentas del issue #34 (registro, login y logout). El historial y los saldos provienen de la API. El consumo semanal incluye las apuestas registradas desde el lunes en la hora local del servidor. Los registros antiguos sin fecha permanecen en el historial.

## Probar el flujo completo

1. En una terminal desde `backend`, ejecuta `python -m tests.servidor_flutter`. Esto inicia un servidor de prueba en el puerto 18810 con una base temporal nueva.
2. Desde `mobile`, ejecuta `flutter test -d windows integration_test/apuestas_test.dart --dart-define=API_URL=http://127.0.0.1:18810`.
3. Termina el servidor de prueba con Ctrl+C. Para repetir el recorrido desde el saldo inicial, reinícialo.

Para las pruebas de navegación con datos controlados, ejecuta `flutter test` desde `mobile`.

## Administración (#39)

La administración requiere la API en modo PostgreSQL y una cuenta activa con rol administrador. En una instalación existente, aplicar la versión actual de `database/distribuido/init/21_directorio_cuentas.sql` al primario impar. Al iniciar sesión aparece el acceso a Administración. Cuentas muestra el alias y el estado. En Jornadas, elige deporte, fecha, hora local y dos equipos del catálogo. «Guardar y agregar otro» conserva la jornada y limpia los equipos. El catálogo debe contener al menos dos equipos del deporte elegido.

Flutter consume `GET /admin/cuentas` (lista), `GET /admin/equipos` y `POST /admin/partidos`. Envía los identificadores de deporte y equipos, y la fecha y hora convertidas a UTC. PostgreSQL impide repetir el mismo encuentro a la misma hora.

Ejecuta `flutter test test/administracion_test.dart` para comprobar la captura consecutiva con un catálogo simulado.

Para repetir la integración en Windows, usa una base PostgreSQL de prueba con el catálogo de ejemplo (Chiefs y Eagles), una cuenta administradora activa y sin esos encuentros registrados hoy a mediodía. Desde `mobile` ejecuta `flutter test -d windows integration_test/administracion_test.dart --dart-define=API_URL=http://127.0.0.1:8000 --dart-define=ADMIN_PRUEBA=ALIAS_DE_PRUEBA --dart-define=CLAVE_PRUEBA=CLAVE_DE_PRUEBA`. La prueba crea dos partidos en esa base.

## Estadísticas (#43)

En Estadísticas, «Mis resultados» muestra la evolución diaria del bankroll y la ganancia deportiva, el ROI por deporte y las rachas en orden de resolución. Cada gráfica muestra «Sin datos» si le falta información. La API genera las imágenes al solicitar `GET /usuarios/{id}/resultados?graficas=true`. Instala las dependencias actualizadas de `backend/requirements.txt` para incluir Matplotlib.

«Globales» muestra los conteos por deporte y partido del último corte de MongoDB. La hora se presenta en la zona local del dispositivo. Si todavía no hay un corte, la pantalla indica «Sin datos». Si el servicio falla, ofrece reintentar.

Para repetir la prueba de Windows, inicia MongoDB de pruebas con `docker compose -f analytics/compose.yaml up -d` desde la raíz. Instala las dependencias de `analytics/requirements.txt` y ejecuta `python analytics/procesar.py` para publicar un corte. Inicia la API temporal con `python -m tests.servidor_flutter` desde `backend`. Desde `mobile`, ejecuta `flutter test -d windows integration_test/estadisticas_test.dart --dart-define=API_URL=http://127.0.0.1:18810`. El recorrido crea una cuenta temporal, resuelve una apuesta ganada y consulta ambos reportes.
