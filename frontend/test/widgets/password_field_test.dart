// PasswordField eye toggle + PasswordRequirements checklist. The rules must
// mirror server/src/common/password.ts (passwordPolicyViolation +
// chosenPasswordViolation's MAX_PASSWORD_LENGTH) — nothing more.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:srisurart_pos/presentation/widgets/app_text_field.dart';
import 'package:srisurart_pos/presentation/widgets/password_field.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(16), child: child),
  ),
);

bool _obscured(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).obscureText;

void main() {
  group('PasswordField', () {
    testWidgets('starts hidden; the eye shows, then hides again', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const PasswordField()));
      expect(_obscured(tester), isTrue);
      expect(find.byTooltip(PasswordField.showTooltip), findsOneWidget);

      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pump();
      expect(_obscured(tester), isFalse);
      expect(find.byTooltip(PasswordField.hideTooltip), findsOneWidget);

      await tester.tap(find.byIcon(Icons.visibility_off));
      await tester.pump();
      expect(_obscured(tester), isTrue);
    });

    testWidgets(
      'AppTextField(obscureText: true) gets the toggle; plain does not',
      (tester) async {
        await tester.pumpWidget(
          _host(
            const Column(
              children: [
                AppTextField(label: 'รหัสผ่าน', obscureText: true),
                AppTextField(label: 'ชื่อผู้ใช้'),
              ],
            ),
          ),
        );
        expect(find.byType(PasswordField), findsOneWidget);
        expect(find.byTooltip(PasswordField.showTooltip), findsOneWidget);
        final fields = tester
            .widgetList<TextField>(find.byType(TextField))
            .toList();
        expect(fields[0].obscureText, isTrue);
        expect(fields[1].obscureText, isFalse);
      },
    );
  });

  group('PasswordField extras', () {
    testWidgets('disabled field: the eye is disabled too', (tester) async {
      await tester.pumpWidget(_host(const PasswordField(enabled: false)));
      final btn = tester.widget<IconButton>(find.byType(IconButton));
      expect(btn.onPressed, isNull);
    });

    testWidgets('isPin: the tooltip says PIN', (tester) async {
      await tester.pumpWidget(
        _host(const AppTextField(obscureText: true, isPin: true)),
      );
      expect(find.byTooltip(PasswordField.showPinTooltip), findsOneWidget);
      expect(find.byTooltip(PasswordField.showTooltip), findsNothing);
    });

    testWidgets('AppTextField passes initialValue through', (tester) async {
      await tester.pumpWidget(
        _host(const AppTextField(obscureText: true, initialValue: 'abc')),
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'abc',
      );
    });

    test('AppTextField refuses a suffix on a secret field', () {
      expect(
        () => AppTextField(obscureText: true, suffix: const SizedBox()),
        throwsAssertionError,
      );
    });
  });

  group('passwordRules (mirrors server/src/common/password.ts)', () {
    bool met(String pw, {String? confirm}) =>
        passwordRulesMet(pw, confirm: confirm);

    test('length floor is 12 (11 fails, 12 passes)', () {
      expect(met('a' * 11), isFalse);
      expect(met('a' * 12), isTrue);
    });

    test('whitespace-only counts as absent, like the server', () {
      expect(met(' ' * 20), isFalse);
      expect(met('long pass phrase'), isTrue); // inner spaces are fine
    });

    test('upper bound is 128', () {
      expect(met('a' * 128), isTrue);
      expect(met('a' * 129), isFalse);
    });

    test('Thai counts code units like JS .length', () {
      // 'รหัสผ่านของฉัน' is 14 UTF-16 code units, as in JS.
      expect('รหัสผ่านของฉัน'.length, 14);
      expect(met('รหัสผ่านของฉัน'), isTrue);
      expect(met('รหัสผ่าน'), isFalse);
    });

    test('confirm must match when the form has one', () {
      expect(met('a' * 12, confirm: 'a' * 12), isTrue);
      expect(met('a' * 12, confirm: 'b' * 12), isFalse);
      expect(
        passwordRules('x').length,
        2,
      ); // no confirm row without a confirm box
      expect(passwordRules('x', confirm: '').length, 3);
    });
  });

  testWidgets('PasswordRequirements ticks live', (tester) async {
    Future<void> show(String pw, String confirm) => tester.pumpWidget(
      _host(PasswordRequirements(password: pw, confirm: confirm)),
    );

    await show('', '');
    expect(find.text(PasswordRequirements.minLabel), findsOneWidget);
    expect(find.text(PasswordRequirements.maxLabel), findsOneWidget);
    expect(find.text(PasswordRequirements.matchLabel), findsOneWidget);
    expect(find.text(PasswordRequirements.serverNote), findsOneWidget);
    // Empty: nothing is ticked, not even the upper bound.
    expect(find.byKey(const Key('pw-rule-met')), findsNothing);
    expect(find.byKey(const Key('pw-rule-unmet')), findsNWidgets(3));

    await show('my own long passphrase', 'my own long passphrase');
    expect(find.byKey(const Key('pw-rule-met')), findsNWidgets(3));
    expect(find.byKey(const Key('pw-rule-unmet')), findsNothing);
  });
}
