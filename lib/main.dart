import 'package:flutter/material.dart';

import 'package:macdrive_rescue/ui/home_screen.dart';
import 'package:macdrive_rescue/ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MacDriveRescueApp());
}

class MacDriveRescueApp extends StatelessWidget {
  const MacDriveRescueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MacDrive Rescue',
      debugShowCheckedModeBanner: false,
      theme: buildDarkTheme(),
      home: const HomeScreen(),
    );
  }
}
