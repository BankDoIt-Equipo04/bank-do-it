# Bank Do It

Proyecto Integrador del Equipo 04 de Ingeniería en Sistemas Computacionales de la Universidad Autónoma de Aguascalientes.

Bank Do It será una aplicación para registrar apuestas deportivas simuladas y llevar el control del bankroll, es decir, el saldo que cada persona destina a sus apuestas. Está dirigida tanto a quienes empiezan como a quienes ya llevan un historial y quieren saber cuánto han ganado o perdido, cómo les va en cada deporte y si se mantienen dentro de su presupuesto.

## Alcance

- **Bankroll y apuestas.** Cada usuario tendrá un solo saldo simulado. Podrá registrar apuestas simples indicando el deporte, el evento, la selección, el monto y la cuota. Cada apuesta comenzará como pendiente y el usuario podrá marcarla como ganada, perdida o anulada.
- **Presupuesto semanal.** Si una apuesta rebasa el límite que fijó el usuario, la aplicación mostrará por cuánto lo supera y le permitirá confirmar o cancelar el registro.
- **Historial y recuerdos.** Cada persona podrá filtrar sus apuestas por deporte y guardar una foto del momento. Desde Android podrá fotografiar el juego en la televisión o desde su asiento en el estadio. En web y escritorio podrá seleccionar una imagen.
- **Estadísticas.** El usuario podrá consultar tres gráficas generadas con sus propios registros: ganancias o pérdidas acumuladas, retorno sobre lo apostado (ROI) y rachas de apuestas ganadas o perdidas.
- **Administración.** El administrador gestionará las cuentas y supervisará el funcionamiento del sistema.

Todos los movimientos serán simulados. La aplicación no moverá dinero real ni se conectará a casas de apuestas.

## Arquitectura prevista

La aplicación se desarrollará en Flutter con una base de código compartida para Android, web y escritorio nativo. Las tres versiones se comunicarán con una API REST en Python, encargada de validar los registros y actualizar el saldo.

La base de datos relacional se distribuirá entre un equipo local y otro remoto. Se usará `usuario_id` como clave de fragmentación para mantener las apuestas de una persona en el mismo fragmento. Así, al consultar su historial o calcular su ROI, el sistema podrá recuperar sus apuestas desde ese fragmento. Se configurará replicación entre nodos. MongoDB almacenará los datos preparados para el análisis y Matplotlib generará las gráficas.

Para confirmar una apuesta, el sistema priorizará la consistencia del saldo. Si se pierde la conexión, el usuario podrá guardar un borrador en su dispositivo. Cuando vuelva la conexión, la API verificará que haya saldo suficiente antes de confirmarlo. Si el dispositivo envía el mismo borrador dos veces, el monto deberá descontarse una sola vez.

## Infraestructura y presupuesto

La computadora de escritorio de Luis funcionará como servidor principal y otro equipo del grupo se utilizará como nodo remoto. Los servicios se ejecutarán en contenedores con comunicación cifrada, control de acceso y monitoreo. Se utilizarán datos sintéticos en las pruebas.

El gasto adicional previsto es de **$0 MXN**, considerando que el equipo aportará las computadoras y utilizará las conexiones a internet disponibles.

## Integrantes

| Integrante | Responsabilidad principal |
| --- | --- |
| Luis Fernando Barragán Medina | API REST en Python, reglas del bankroll y gráficas de rendimiento, ROI y rachas. |
| Raúl Romo Lamas | Aplicación Flutter para Android, web y escritorio, navegación e integración de la cámara. |
| Osvaldo Yair Serna Salazar | Modelo de datos, fragmentación por usuario, replicación y pruebas de falla de los nodos. |

## Organización del trabajo

Las actividades se registran en los [Issues del proyecto](https://github.com/BankDoIt-Equipo04/bank-do-it/issues). Cada cambio se trabajará en una rama vinculada a su Issue y se integrará a `main` mediante un pull request revisado y aprobado por otro integrante.

El equipo utilizará ChatGPT y Claude como herramientas de apoyo. En la bitácora de IA se documentará qué aportes se incorporaron, por qué se aceptaron y cómo se verificaron.

## Estado del proyecto

El proyecto se encuentra en la primera entrega, dedicada a la propuesta y al diseño inicial. Las instrucciones de instalación y ejecución se agregarán cuando esté disponible la primera versión funcional.
