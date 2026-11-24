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
