import 'package:flutter/material.dart';

import 'tokens.dart';
import 'type.dart';

/// "namao" followed by the accent-coloured dot (the web client's brand mark, in Latin letters).
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 26});

  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      label: 'Namao',
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'namao',
              style: display(
                size,
                FontWeight.w800,
                p.text,
                letterSpacing: -0.8,
              ),
            ),
            TextSpan(
              text: '.',
              style: display(size, FontWeight.w800, p.accent),
            ),
          ],
        ),
        maxLines: 1,
      ),
    );
  }
}
