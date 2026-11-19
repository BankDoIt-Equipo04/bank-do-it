# Resultado de las pruebas del issue #9

Código probado: [f0e62c4](https://github.com/BankDoIt-Equipo04/bank-do-it/commit/f0e62c4).

La prueba abre Dallas vs. Filadelfia desde Mis apuestas y vuelve al historial. Antes y después del recorrido comprueba la apuesta visible, la selección de En curso (1), los $900 de saldo disponible y los $100 en juego.

| Ejecución desde mobile/ | Resultado |
| --- | --- |
| `flutter test --no-pub --reporter expanded` | Pasaron los dos recorridos de widgets con configuraciones Android y Windows. |
| `flutter test --platform chrome --no-pub --reporter expanded` | Pasó el recorrido en Chrome. Para esta ejecución se sirvieron al navegador los archivos CanvasKit del SDK local. |
| `flutter analyze --no-pub` | Sin incidencias. |
