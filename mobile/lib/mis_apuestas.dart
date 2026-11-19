import 'package:flutter/material.dart';

const titulo = TextStyle(fontSize: 28, fontWeight: FontWeight.bold);
const partido = 'Dallas vs. Filadelfia';

class Resumen extends StatelessWidget {
  const Resumen({super.key});
  @override
  Widget build(BuildContext context) {
    const cifras = Row(
      children: [
        Expanded(child: _Importe('Saldo disponible', r'$900')),
        Expanded(child: _Importe('En juego', r'$100')),
      ],
    );
    const presupuesto = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Presupuesto semanal',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(r'$100 de $500'),
        SizedBox(height: 6),
        LinearProgressIndicator(
          value: 0.2,
          color: Colors.grey,
          backgroundColor: Color(0xffdddddd),
        ),
      ],
    );
    Widget panel(Widget child) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xfff1f1f1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
    return LayoutBuilder(
      builder: (_, size) => size.maxWidth < 520
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                panel(cifras),
                const SizedBox(height: 16),
                presupuesto,
              ],
            )
          : panel(
              const Row(
                children: [
                  Expanded(flex: 2, child: cifras),
                  Expanded(child: presupuesto),
                ],
              ),
            ),
    );
  }
}

class _Importe extends StatelessWidget {
  const _Importe(this.nombre, this.valor);
  final String nombre, valor;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(nombre),
      Text(valor, style: titulo),
    ],
  );
}

class MisApuestas extends StatefulWidget {
  const MisApuestas({required this.movil, super.key});
  final bool movil;
  @override
  State<MisApuestas> createState() => _MisApuestasState();
}

class _MisApuestasState extends State<MisApuestas> {
  int seleccion = 0;

  void abrir(Widget pagina) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => pagina));

  @override
  Widget build(BuildContext context) {
    final registrar = FilledButton(
      onPressed: () => abrir(const Registro()),
      child: const Text('+ Registrar apuesta'),
    );
    void detalle() => abrir(const Detalle());
    return LayoutBuilder(
      builder: (context, limites) {
        final estrecho = limites.maxWidth < 520;
        final botonAlPie = widget.movil || estrecho;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(estrecho ? 16 : 28),
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Mis apuestas', style: titulo),
                      ),
                      if (!botonAlPie) registrar,
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Resumen(),
                  const SizedBox(height: 20),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (i, etiqueta) in [
                          'En curso (1)',
                          'Ganadas (0)',
                          'Perdidas (0)',
                        ].indexed)
                          Semantics(
                            selected: seleccion == i,
                            child: TextButton(
                              onPressed: () => setState(() => seleccion = i),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      width: 2,
                                      color: seleccion == i
                                          ? Colors.black
                                          : Colors.transparent,
                                    ),
                                  ),
                                ),
                                child: Text(etiqueta),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: 16),
                  if (seleccion != 0)
                    Text(
                      seleccion == 1
                          ? 'Sin apuestas ganadas.'
                          : 'Sin apuestas perdidas.',
                    )
                  else if (widget.movil)
                    Card.outlined(
                      child: ListTile(
                        onTap: detalle,
                        title: const Text(
                          partido,
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: const Text(
                          'Selección: Dallas\nMonto: \$100   ·   Cuota: 2.00',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                      ),
                    )
                  else
                    LayoutBuilder(
                      builder: (_, area) => SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minWidth: area.maxWidth),
                          child: DataTable(
                            columnSpacing: 18,
                            horizontalMargin: 12,
                            headingRowColor: const WidgetStatePropertyAll(
                              Color(0xffeeeeee),
                            ),
                            columns: [
                              for (final col in [
                                'Partido',
                                'Selección',
                                'Monto',
                                'Cuota',
                                '',
                              ])
                                DataColumn(label: Text(col)),
                            ],
                            rows: [
                              DataRow(
                                cells: [
                                  const DataCell(Text(partido)),
                                  const DataCell(Text('Dallas')),
                                  const DataCell(Text(r'$100')),
                                  const DataCell(Text('2.00')),
                                  DataCell(
                                    TextButton(
                                      onPressed: detalle,
                                      child: const Text('Ver detalle'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (botonAlPie)
              Padding(padding: const EdgeInsets.all(16), child: registrar),
          ],
        );
      },
    );
  }
}

class Registro extends StatelessWidget {
  const Registro({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Registrar apuesta')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          for (final campo in [
            'Deporte',
            'Partido',
            'Selección',
            'Monto',
            'Cuota',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: TextField(
                decoration: InputDecoration(labelText: campo),
                keyboardType: campo == 'Monto' || campo == 'Cuota'
                    ? const TextInputType.numberWithOptions(decimal: true)
                    : TextInputType.text,
              ),
            ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    ),
  );
}

class Detalle extends StatelessWidget {
  const Detalle({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Detalle de apuesta')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(partido, style: titulo),
        const SizedBox(height: 16),
        for (final dato in const [
          ('Estado', 'En curso'),
          ('Deporte', 'Fútbol americano'),
          ('Selección', 'Dallas'),
          ('Monto', r'$100'),
          ('Cuota', '2.00'),
        ])
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(dato.$1),
            trailing: Text(dato.$2),
          ),
      ],
    ),
  );
}
