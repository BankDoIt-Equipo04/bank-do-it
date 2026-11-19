# Prueba de reconexión del issue #12

Desde la raíz del repositorio, con Flutter y las dependencias de `backend/requirements.txt` instaladas, usen dos terminales. El servidor de prueba crea una base temporal nueva al arrancar.

1. En la primera terminal, ejecuten `cd backend` y luego `python -m tests.servidor_flutter`. Déjenla abierta.
2. En la segunda, ejecuten `cd mobile` y después:

   ```powershell
   flutter test --dart-define=PRUEBA_API_TEMPORAL=true --dart-define=API_URL=http://127.0.0.1:18810 test/borradores_test.dart
   ```

La prueba empieza con $1000 disponibles. Flutter envía una apuesta de $100 y la API responde 201. La prueba interrumpe la entrega de esa respuesta a Flutter, vuelve a abrir el almacén de borradores sin conexión y comprueba que conserva el saldo y la fecha anteriores. Al reconectar, reenvía la misma clave y los mismos datos. La API devuelve 200 y el historial contiene una apuesta, $900 disponibles y $100 en juego. El borrador desaparece. Para repetir la prueba desde $1000, detengan el servidor con Ctrl+C y vuelvan a iniciarlo.

### Comprobación visual en Chrome

1. Con el servidor temporal en marcha, desde `mobile` inicien `flutter run -d chrome --web-port=18812 --dart-define=API_URL=http://127.0.0.1:18810`. Esperen a que «Mis apuestas» muestre el saldo inicial.
2. En las herramientas de desarrollo de Chrome, abran **Network** y seleccionen **Offline**. Registren una apuesta con una selección reconocible. En «Mis apuestas» deben ver **Pendiente de sincronizar** y la fecha del último saldo confirmado.
3. En **Network**, vuelvan a **No throttling**. Dejen «Mis apuestas» abierta. En el siguiente reintento automático (cada 10 segundos) debe aparecer la confirmación de la API. También pueden pulsar **Actualizar historial**.
4. Para la evidencia, capturen el borrador pendiente y luego la apuesta confirmada con el nuevo saldo. Para comprobar específicamente la pérdida de la respuesta después de guardar, usen la prueba de las dos terminales.
