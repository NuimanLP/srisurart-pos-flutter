// Widget tests for DevicesScreen (Slice 21, #192).

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/repositories/auth_repository.dart';
import 'package:srisurart_pos/data/repositories/devices_repository.dart';
import 'package:srisurart_pos/domain/models/auth_models.dart';
import 'package:srisurart_pos/domain/models/device_model.dart';
import 'package:srisurart_pos/presentation/blocs/auth_cubit.dart';
import 'package:srisurart_pos/presentation/screens/devices_screen.dart';

import 'auth_repository_test.dart';

class FakeDevicesRepository implements DevicesRepository {
  List<DeviceModel> devices = [];
  String? nextEnrolCode = '123456';
  String? lastRetiredId;
  double? lastPhysicalCash;
  bool? lastForce;
  String? lastNote;

  int listCalls = 0;
  Object? listError;

  @override
  Future<List<DeviceModel>> listDevices() async {
    listCalls++;
    if (listError != null) throw listError!;
    return List.of(devices);
  }

  @override
  Future<({DeviceModel device, String enrolCode})> createDevice({
    required String label,
    required String role,
  }) async {
    final dev = DeviceModel(
      id: 'dev_${devices.length + 1}',
      label: label,
      deviceNo: devices.length + 1,
      role: role,
      enrolled: false,
      enrolExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
    );
    devices.add(dev);
    return (device: dev, enrolCode: nextEnrolCode ?? '999999');
  }

  @override
  Future<void> retireDevice({
    required String deviceId,
    double? physicalCash,
    bool? force,
    String? note,
  }) async {
    lastRetiredId = deviceId;
    lastPhysicalCash = physicalCash;
    lastForce = force;
    lastNote = note;

    final idx = devices.indexWhere((d) => d.id == deviceId);
    if (idx != -1) {
      final old = devices[idx];
      devices[idx] = DeviceModel(
        id: old.id,
        label: old.label,
        deviceNo: old.deviceNo,
        role: old.role,
        retiredAt: DateTime.now(),
        enrolled: old.enrolled,
        unsyncedOps: 0,
      );
    }
  }
}

Widget buildTestWidget({
  required Widget child,
  required FakeDevicesRepository devicesRepo,
  required AuthCubit authCubit,
}) {
  return MultiRepositoryProvider(
    providers: [
      RepositoryProvider<DevicesRepository>.value(value: devicesRepo),
    ],
    child: BlocProvider<AuthCubit>.value(
      value: authCubit,
      child: MaterialApp(
        home: child,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeDevicesRepository devicesRepo;
  late FakeTokenStorage tokenStorage;
  late AuthRepository authRepo;
  late AuthCubit authCubit;

  setUp(() {
    devicesRepo = FakeDevicesRepository();
    tokenStorage = FakeTokenStorage();
    final mockHttp = MockClient((_) async => http.Response('{}', 200));
    authRepo = AuthRepository(
      apiClient: ApiClient(
        baseUrl: 'http://localhost:3000',
        tokenStorage: tokenStorage,
        httpClient: mockHttp,
      ),
      tokenStorage: tokenStorage,
    );
    authCubit = AuthCubit(authRepository: authRepo);
    authCubit.emit(const Authenticated(
      user: AuthUser(id: 'u1', username: 'owner', role: 'owner'),
      deviceToken: 'pos-token',
      deviceRole: 'pos',
    ));
  });

  tearDown(() {
    authCubit.close();
  });

  testWidgets('DevicesScreen renders device list, badges, and unsynced ops warning', (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    devicesRepo.devices = [
      DeviceModel(
        id: 'dev_01',
        label: 'เครื่องขายหลัก',
        deviceNo: 1,
        role: 'pos',
        enrolled: true,
        unsyncedOps: 2,
        unsyncedReportedAt: DateTime.now(),
        lastSeenAt: DateTime.now(),
      ),
      DeviceModel(
        id: 'dev_02',
        label: 'เครื่องหลังร้าน',
        deviceNo: 2,
        role: 'backoffice',
        enrolled: true,
        unsyncedOps: 0,
        lastSeenAt: DateTime.now(),
      ),
      DeviceModel(
        id: 'dev_03',
        label: 'เครื่องเก่า',
        deviceNo: 3,
        role: 'pos',
        retiredAt: DateTime.now(),
        enrolled: true,
      ),
    ];

    await tester.pumpWidget(buildTestWidget(
      child: const DevicesScreen(),
      devicesRepo: devicesRepo,
      authCubit: authCubit,
    ));
    await tester.pumpAndSettle();

    // Verify Title and Guidelines
    expect(find.text('จัดการเครื่อง (Device Management)'), findsOneWidget);
    expect(find.textContaining('เครื่องขาย POS อนุญาตให้มีได้ 1 เครื่องต่อร้านค้า'), findsOneWidget);

    // Verify Device items rendered
    expect(find.text('เครื่องขายหลัก'), findsOneWidget);
    expect(find.text('เครื่องหลังร้าน'), findsOneWidget);
    expect(find.text('เครื่องเก่า'), findsOneWidget);

    // Verify #01, #02, #03 numbers
    expect(find.text('#01'), findsOneWidget);
    expect(find.text('#02'), findsOneWidget);
    expect(find.text('#03'), findsOneWidget);

    // Verify Unsynced ops warning
    expect(find.textContaining('มีรายการขายค้างส่ง 2 รายการ'), findsOneWidget);

    // Verify Status chips
    expect(find.text('ปลดระวางแล้ว'), findsOneWidget);
    expect(find.text('เชื่อมต่อแล้ว'), findsNWidgets(2));
  });

  // #558: a session with no device token cannot use any /devices route.
  testWidgets('no device token: explains how to enrol, never calls the server, hides issue-code', (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    authCubit.emit(const Authenticated(
      user: AuthUser(id: 'u1', username: 'owner', role: 'owner'),
    ));

    await tester.pumpWidget(buildTestWidget(
      child: const DevicesScreen(),
      devicesRepo: devicesRepo,
      authCubit: authCubit,
    ));
    await tester.pumpAndSettle();

    expect(devicesRepo.listCalls, 0);
    expect(find.text('เบราว์เซอร์นี้ยังไม่ได้ผูกเครื่องกับร้าน'), findsOneWidget);
    expect(find.textContaining('กรุณาติดต่อผู้ดูแลระบบ'), findsOneWidget);
    expect(find.text('ออกรหัสผูกเครื่องใหม่'), findsNothing);
    expect(find.text('เครื่องนี้ขายของไม่ได้'), findsNothing);
    expect(find.text('ลองใหม่อีกครั้ง'), findsNothing);
    // The enrol action is offered (header + panel).
    expect(find.text('ผูกเครื่องนี้'), findsNWidgets(2));
  });

  testWidgets('403 DEVICE_ROLE_FORBIDDEN with a stored device token asks to sign in again', (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    devicesRepo.listError =
        const PosException('DEVICE_ROLE_FORBIDDEN', 'เครื่องนี้ขายของไม่ได้');

    await tester.pumpWidget(buildTestWidget(
      child: const DevicesScreen(),
      devicesRepo: devicesRepo,
      authCubit: authCubit,
    ));
    await tester.pumpAndSettle();

    expect(devicesRepo.listCalls, 1);
    expect(find.textContaining('กรุณาออกจากระบบแล้วเข้าสู่ระบบใหม่'), findsOneWidget);
    expect(find.text('ออกจากระบบ'), findsOneWidget);
    expect(find.text('ออกรหัสผูกเครื่องใหม่'), findsNothing);
    expect(find.text('เครื่องนี้ขายของไม่ได้'), findsNothing);
  });

  testWidgets('any other load error keeps the generic error and retry', (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    devicesRepo.listError = ApiException(statusCode: 500, code: '');

    await tester.pumpWidget(buildTestWidget(
      child: const DevicesScreen(),
      devicesRepo: devicesRepo,
      authCubit: authCubit,
    ));
    await tester.pumpAndSettle();

    expect(find.text('ลองใหม่อีกครั้ง'), findsOneWidget);
    expect(find.text('เบราว์เซอร์นี้ยังไม่ได้ผูกเครื่องกับร้าน'), findsNothing);
  });

  testWidgets('CreateDeviceDialog generates code and displays EnrolCodeDisplayDialog', (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    devicesRepo.devices = [];
    devicesRepo.nextEnrolCode = '888123';

    await tester.pumpWidget(buildTestWidget(
      child: const DevicesScreen(),
      devicesRepo: devicesRepo,
      authCubit: authCubit,
    ));
    await tester.pumpAndSettle();

    // Tap "ออกรหัสผูกเครื่องใหม่" button
    final createBtn = find.text('ออกรหัสผูกเครื่องใหม่');
    expect(createBtn, findsWidgets);
    await tester.tap(createBtn.first);
    await tester.pumpAndSettle();

    // Verify dialog opened
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('สร้างรหัสผูกเครื่อง'), findsOneWidget);
    expect(find.text('เครื่องขาย (POS)'), findsOneWidget);

    // Enter label
    final labelField = find.widgetWithText(TextField, '');
    await tester.enterText(labelField, 'เคาน์เตอร์ใหม่');
    await tester.pump();

    // Tap submit
    final submitBtn = find.text('สร้างรหัสผูกเครื่อง');
    await tester.tap(submitBtn);
    await tester.pumpAndSettle();

    // Verify code display dialog shown
    expect(find.text('รหัสผูกเครื่องของคุณ'), findsOneWidget);
    expect(find.text('888123'), findsOneWidget);

    // Dismiss dialog
    await tester.tap(find.text('รับทราบ / ปิดหน้าต่าง'));
    await tester.pumpAndSettle();

    // List should now have the newly created device
    expect(find.text('เคาน์เตอร์ใหม่'), findsOneWidget);
  });

  testWidgets('RetireDeviceDialog submits retire request with cash and force note', (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    devicesRepo.devices = [
      DeviceModel(
        id: 'dev_pos',
        label: 'POS จะปลด',
        deviceNo: 1,
        role: 'pos',
        enrolled: true,
        unsyncedOps: 1,
      ),
    ];

    await tester.pumpWidget(buildTestWidget(
      child: const DevicesScreen(),
      devicesRepo: devicesRepo,
      authCubit: authCubit,
    ));
    await tester.pumpAndSettle();

    // Tap "ปลดเครื่อง"
    await tester.tap(find.text('ปลดเครื่อง'));
    await tester.pumpAndSettle();

    expect(find.textContaining('คุณแน่ใจหรือไม่ว่าต้องการปลดระวางเครื่อง "POS จะปลด"?'), findsOneWidget);

    // Enter physical cash and force note
    final textFields = find.byType(TextField);
    await tester.enterText(textFields.at(0), '500'); // physical cash
    await tester.enterText(textFields.at(1), 'เครื่องไฟไหม้'); // note
    await tester.pump();

    // Tap confirm retire
    await tester.tap(find.text('ยืนยันปลดระวางเครื่อง'));
    await tester.pumpAndSettle();

    expect(devicesRepo.lastRetiredId, 'dev_pos');
    expect(devicesRepo.lastPhysicalCash, 500.0);
    expect(devicesRepo.lastForce, isTrue);
    expect(devicesRepo.lastNote, 'เครื่องไฟไหม้');

    // Verify success snackbar
    expect(find.textContaining('ปลดระวางเครื่อง #01 (POS จะปลด) เรียบร้อยแล้ว'), findsOneWidget);
  });
}
