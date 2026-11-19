# Recuerdo fotográfico de una apuesta · Issue #11

| Plataforma | Verificación | Evidencia |
| --- | --- | --- |
| Android | La prueba de Flutter solicita la cámara al pulsar **Tomar foto**, procesa una imagen de prueba y comprueba que cancelar conserva la foto existente. La captura se renderizó con configuración Android. La cámara física queda pendiente. | [Detalle en Android simulado](android-simulado.png) |
| Web | En Chrome se seleccionó un PNG mediante el selector del navegador y se comprobó que quedaba visible. El evento de cancelación conservó la imagen. | [Detalle en Chrome](web.png) |
| Windows | En la aplicación nativa se abrió el diálogo **Abrir**, se adjuntó el PNG y se canceló un segundo intento. La API devolvió la misma imagen. | [Detalle en Windows](windows.png) |

La imagen es una cancha sintética. Las pruebas comprueban que una segunda apuesta sigue sin foto y que el saldo permanece igual. La demo almacena una foto por apuesta en SQLite y valida que el identificador de usuario de la ruta corresponda a la apuesta. Sigue usando el usuario de demostración sin inicio de sesión.

Para reproducir las pruebas, ejecutar `flutter test test/recuerdo_test.dart` desde `mobile` y `python -m pytest -q` desde `backend`. Al actualizar una demo existente, instalar las dependencias de `requirements.txt`, ejecutar `python -m app.datos_demo` y reiniciar la API.
