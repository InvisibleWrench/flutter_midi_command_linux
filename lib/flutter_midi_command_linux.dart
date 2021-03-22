import 'dart:async';
import 'package:ffi/ffi.dart';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:tuple/tuple.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'alsa_generated_bindings.dart' as a;

final alsa = a.ALSA(DynamicLibrary.open("libasound.so.2"));

final int SND_RAWMIDI_STREAM_INPUT = 1;
final int SND_RAWMIDI_STREAM_OUTPUT = 0;

int lengthOfMessageType(int type) {
  int midiType = type & 0xF0;

  switch (type) {
    case 0xF6:
    case 0xF8:
    case 0xFA:
    case 0xFB:
    case 0xFC:
    case 0xFF:
    case 0xFE:
      return 1;
    case 0xF1:
    case 0xF3:
      return 2;
    default:
      break;
  }

  switch (midiType) {
    case 0xC0:
    case 0xD0:
      return 2;
    case 0xF2:
    case 0x80:
    case 0x90:
    case 0xA0:
    case 0xB0:
    case 0xE0:
      return 3;
    default:
      break;
  }
  return 0;
}

void _rxIsolate(Tuple2<SendPort, int> args) {
  final sendPort = args.item1;
  final Pointer<a.snd_rawmidi_> inPort = Pointer<a.snd_rawmidi_>.fromAddress(args.item2);

  print("start isolate $sendPort, $inPort, ${args.item2}");

  int status = 0;
  int msgLength = 0;
  Pointer<Uint8> buffer = calloc<Uint8>(); // allocate(count: 1);
  List<int> rxBuffer = [];

  while (true) {
    if (inPort == null) {
      print("no inport");
      break;
    }

    if ((status = alsa.snd_rawmidi_read(inPort, buffer.cast(), 1)) < 0) {
      print("Problem reading MIDI input:${FlutterMidiCommandLinux.stringFromNative(alsa.snd_strerror(status))}");
    } else {
      // print("byte ${buffer.value}");
      if (rxBuffer.length == 0) {
        msgLength = lengthOfMessageType(buffer.value);
      }

      rxBuffer.add(buffer.value);

      if (rxBuffer.length == msgLength) {
        // print("send buffer $rxBuffer $msgLength");
        sendPort.send(Uint8List.fromList(rxBuffer));
        rxBuffer.clear();
      }
    }
  }
}

class LinuxMidiDevice extends MidiDevice {
  Pointer<Pointer<a.snd_rawmidi_>>? outPort;
  Pointer<Pointer<a.snd_rawmidi_>>? inPort;
  StreamController<MidiPacket> _rxStreamCtrl;
  Isolate? _isolate;

  Pointer<a.snd_ctl_> ctl;
  int cardId;
  int deviceId;

  LinuxMidiDevice(this.ctl, this.cardId, this.deviceId, String name, String type, this._rxStreamCtrl) : super("hw:$cardId,$deviceId", name, type, false) {
    // Fetch device info
    Pointer<Pointer<a.snd_rawmidi_info_>> info = calloc<Pointer<a.snd_rawmidi_info_>>();
    alsa.snd_rawmidi_info_malloc(info);
    alsa.snd_rawmidi_info_set_device(info.value, deviceId);

    int status = alsa.snd_ctl_rawmidi_info(ctl, info.value);
    if (status < 0) {
      print('error: cannot get device info.value ${alsa.snd_strerror(status).cast<Utf8>().toDartString()}');
      return;
    }

    // Get input ports
    alsa.snd_rawmidi_info_set_stream(info.value, SND_RAWMIDI_STREAM_INPUT);
    status = alsa.snd_ctl_rawmidi_info(ctl, info.value);
    int inCount = alsa.snd_rawmidi_info_get_subdevices_count(info.value);
    for (var i = 0; i < inCount; i++) {
      if (alsa.snd_rawmidi_info_get_subdevice(info.value) > -1) {
        // print("sub in [$i] $status ${alsa.snd_rawmidi_info_get_subdevice_name(info.value).cast<Utf8>().toDartString()}");
        inputPorts.add(MidiPort(i, MidiPortType.IN));
      }
    }

    // Get output ports
    alsa.snd_rawmidi_info_set_stream(info.value, SND_RAWMIDI_STREAM_OUTPUT);
    status = alsa.snd_ctl_rawmidi_info(ctl, info.value);
    int outCount = alsa.snd_rawmidi_info_get_subdevices_count(info.value);
    for (var i = 0; i < outCount; i++) {
      if (alsa.snd_rawmidi_info_get_subdevice(info.value) > -1) {
        // print("sub in [$i] $status ${alsa.snd_rawmidi_info_get_subdevice_name(info.value).cast<Utf8>().toDartString()}");
        outputPorts.add(MidiPort(i, MidiPortType.OUT));
      }
    }

    calloc.free(info);
  }

  Future<bool> connect() async {
    outPort = calloc<Pointer<a.snd_rawmidi_>>();
    inPort = calloc<Pointer<a.snd_rawmidi_>>();

    Pointer<Int8> name = "hw:$cardId,$deviceId,0".toNativeUtf8().cast<Int8>();
    print("open out port ${FlutterMidiCommandLinux.stringFromNative(name)}");
    int status = 0;
    if ((status = alsa.snd_rawmidi_open(inPort!, outPort!, name, a.SND_RAWMIDI_SYNC)) < 0) {
      print('error: cannot open card number $cardId ${FlutterMidiCommandLinux.stringFromNative(alsa.snd_strerror(status))}');
      return false;
    }

    connected = true;

    final errorPort = new ReceivePort();
    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_rxIsolate, Tuple2(receivePort.sendPort, inPort!.value.address), onError: errorPort.sendPort).catchError((err, stackTrace) {
      print("Could not launch RX isolate. $err\nStackTrace: $stackTrace");
    });

    errorPort.listen((message) {
      print('isolate error message $message');
    });

    receivePort.listen((data) {
      // print("rx data $data $_rxStreamCtrl ${_rxStreamCtrl.sink}");
      var packet = MidiPacket(data, DateTime.now().millisecondsSinceEpoch, this);
      _rxStreamCtrl.add(packet);
    });

    return true;
  }

  send(Pointer<Uint8> buffer, int length) {
    if (outPort != null) {
      final voidBuffer = buffer.cast<Void>();

      int status;
      if ((status = alsa.snd_rawmidi_write(outPort!.value, voidBuffer, length)) < 0) {
        print('failed to write ${alsa.snd_strerror(status).cast<Utf8>().toDartString()}');
      }
    } else {
      print('outport is null');
    }
  }

  disconnect() {
    _isolate?.kill(priority: Isolate.immediate);

    int status = 0;
    if (outPort != null) {
      if ((status = alsa.snd_rawmidi_drain(outPort!.value)) < 0) {
        print('error: cannot drain out port $this ${FlutterMidiCommandLinux.stringFromNative(alsa.snd_strerror(status))}');
      }
      if ((status = alsa.snd_rawmidi_close(outPort!.value)) < 0) {
        print('error: cannot close out port $this ${FlutterMidiCommandLinux.stringFromNative(alsa.snd_strerror(status))}');
      }
    }
    if (inPort != null) {
      if ((status = alsa.snd_rawmidi_drain(inPort!.value)) < 0) {
        print('error: cannot drain in port $this ${FlutterMidiCommandLinux.stringFromNative(alsa.snd_strerror(status))}');
      }
      if ((status = alsa.snd_rawmidi_close(inPort!.value)) < 0) {
        print('error: cannot close in port $this ${FlutterMidiCommandLinux.stringFromNative(alsa.snd_strerror(status))}');
      }
    }

    connected = false;
  }
}

class FlutterMidiCommandLinux extends MidiCommandPlatform {
  StreamController<MidiPacket> _rxStreamController = StreamController<MidiPacket>.broadcast();
  late Stream<MidiPacket> _rxStream;
  StreamController<String> _setupStreamController = StreamController<String>.broadcast();
  late Stream<String> _setupStream;

  Map<String, LinuxMidiDevice> _connectedDevices = Map<String, LinuxMidiDevice>();

  /// A constructor that allows tests to override the window object used by the plugin.
  FlutterMidiCommandLinux() {
    _setupStream = _setupStreamController.stream;
    _rxStream = _rxStreamController.stream;
  }

  static String stringFromNative(Pointer<Int8> pointer) {
    return pointer.cast<Utf8>().toDartString();
  }

  /// The linux implementation of [MidiCommandPlatform]
  ///
  /// This class implements the `package:flutter_midi_command_platform_interface` functionality for linux
  static void registerWith() {
    print("register FlutterMidiCommandLinux");
    MidiCommandPlatform.instance = FlutterMidiCommandLinux();
  }

  @override
  Future<List<MidiDevice>> get devices async {
    // _printMidiPorts();
    return Future.value(_printCardList());
  }

  List<MidiDevice>? _printCardList() {
    print("_printCardList");
    int status;
    var card = calloc<Int32>();
    card.elementAt(0).value = -1;
    Pointer<Pointer<Int8>> longname = calloc<Pointer<Int8>>();
    Pointer<Pointer<Int8>> shortname = calloc<Pointer<Int8>>();

    List<MidiDevice> cards = [];

    if ((status = alsa.snd_card_next(card)) < 0) {
      print('error: cannot determine card number $card ${stringFromNative(alsa.snd_strerror(status))}');
      return null;
    }
    // print('status $status');
    if (card.value < 0) {
      print('error: no sound cards found');
      return null;
    }

    while (card.value >= 0) {
      // print("card ${card.value}");
      if ((status = alsa.snd_card_get_name(card.value, shortname)) < 0) {
        print('error: cannot determine card shortname $card ${stringFromNative(alsa.snd_strerror(status))}');
        continue;
      }
      // print('status $status');
      // if ((status = alsa.snd_card_get_longname(card.value, longname)) < 0) {
      //   print(
      //       'error: cannot determine card longname $card ${stringFromNative(alsa.snd_strerror(status))}');
      //   break;
      // }
      // print('status $status');
      print("card shortname ${stringFromNative(shortname.value)} card ${card.value}");

      // bool isMidiCapable = _listMidiDevicesOnCard(card.value);

      // if (isMidiCapable) {
      //   cards.add(LinuxMidiDevice(card.value.toString(), stringFromNative(shortname.value), "native", _rxStreamController));
      // }

      Pointer<Pointer<a.snd_ctl_>> ctl = calloc<Pointer<a.snd_ctl_>>();
      Pointer<Int8> name = "hw:${card.value}".toNativeUtf8().cast<Int8>();
      Pointer<Int32> device = calloc<Int32>();
      device.elementAt(0).value = -1;
      status = -1;

      print('device on card [$card] ${stringFromNative(name)} ctl: $ctl device $device status $status');
      status = alsa.snd_ctl_open(ctl, name, 0);
      print("status after ctl_open $status ctl $ctl ctl.value ${ctl.value}");
      if (status < 0) {
        print('error: cannot open control for card number $card ${stringFromNative(alsa.snd_strerror(status))}');
        continue;
      }
      // print("do device.value ${device.value}");
      do {
        print("ctl $ctl ${ctl.value} device $device");
        status = alsa.snd_ctl_rawmidi_next_device(ctl.value, device);
        print("status $status device.value ${device.value}");
        if (status < 0) {
          print('error: cannot determine device number ${device.value} ${stringFromNative(alsa.snd_strerror(status))}');
          break;
        }
        if (device.value >= 0) {
          // _listSubdeviceInfo(ctl.value, device.value);
          cards.add(LinuxMidiDevice(ctl.value, card.value, device.value, stringFromNative(shortname.value), "native", _rxStreamController));
        }
      } while (device.value > 0);

      if ((status = alsa.snd_card_next(card)) < 0) {
        print('error: cannot determine card number $card ${stringFromNative(alsa.snd_strerror(status))}');
        return cards;
        // continue;
      }
    }

    return cards;
  }

  // void _printMidiPorts() {
  //   print("_printMidiPorts");
  //   int status;
  //   var card = calloc<Int32>();
  //   card.elementAt(0).value = -1;

  //   if ((status = alsa.snd_card_next(card)) < 0) {
  //     print('error: cannot determine card number $card ${stringFromNative(alsa.snd_strerror(status))}');
  //     return;
  //   }
  //   if (card.value < 0) {
  //     print('error: no sound cards found');
  //     return;
  //   }

  //   print('device:');
  //   while (card.value >= 0) {
  //     // print("card value ${card.value}");
  //     _listMidiDevicesOnCard(card.value);

  //     if ((status = alsa.snd_card_next(card)) < 0) {
  //       print('error: cannot determine next card number $card ${stringFromNative(alsa.snd_strerror(status))}');
  //       break;
  //     }
  //   }
  //   print('end');
  // }

  // bool _listMidiDevicesOnCard(int card) {
  //   Pointer<Pointer<a.snd_ctl_>> ctl = calloc<Pointer<a.snd_ctl_>>();
  //   Pointer<Int8> name = "hw:$card".toNativeUtf8().cast<Int8>();
  //   Pointer<Int32> device = calloc<Int32>();
  //   device.elementAt(0).value = -1;
  //   int status = -1;

  //   print('device on card [$card] ${stringFromNative(name)} ctl: $ctl device $device status $status');
  //   status = alsa.snd_ctl_open(ctl, name, 0);
  //   print("status after ctl_open $status ctl $ctl ctl.value ${ctl.value}");
  //   if (status < 0) {
  //     print('error: cannot open control for card number $card ${stringFromNative(alsa.snd_strerror(status))}');
  //     return false;
  //   }
  //   // print("do device.value ${device.value}");
  //   do {
  //     print("ctl $ctl ${ctl.value} device $device");
  //     status = alsa.snd_ctl_rawmidi_next_device(ctl.value, device);
  //     print("status $status device.value ${device.value}");
  //     if (status < 0) {
  //       print('error: cannot determine device number ${device.value} ${stringFromNative(alsa.snd_strerror(status))}');
  //       break;
  //     }
  //     if (device.value >= 0) {
  //       _listSubdeviceInfo(ctl.value, device.value);
  //       return true;
  //     }
  //   } while (device.value > 0);
  //   return false;
  // }

  // void _listSubdeviceInfo(Pointer<a.snd_ctl_> ctl, int device) {
  //   Pointer<Pointer<a.snd_rawmidi_info_>> info = calloc<Pointer<a.snd_rawmidi_info_>>();
  //   alsa.snd_rawmidi_info_malloc(info);

  //   alsa.snd_rawmidi_info_set_device(info.value, device);

  //   Pointer<Int8> name = calloc<Int8>();

  //   print("_listSubdeviceInfo ctl $ctl device $device info $device");

  //   alsa.snd_rawmidi_info_set_stream(info.value, SND_RAWMIDI_STREAM_INPUT);
  //   alsa.snd_ctl_rawmidi_info(ctl, info.value);
  //   int subs_in = alsa.snd_rawmidi_info_get_subdevices_count(info.value);
  //   print("subs_in $subs_in");
  //   alsa.snd_rawmidi_info_set_stream(info.value, SND_RAWMIDI_STREAM_OUTPUT);
  //   alsa.snd_ctl_rawmidi_info(ctl, info.value);
  //   int subs_out = alsa.snd_rawmidi_info_get_subdevices_count(info.value);
  //   print("subs_out $subs_out");

  //   int status = alsa.snd_ctl_rawmidi_info(ctl, info.value);
  //   print("status $status info.value ${info.value}");
  //   if (status < 0) {
  //     print('error: cannot get device info.value ${stringFromNative(alsa.snd_strerror(status))}');
  //     return;
  //   }
  //   print('info.value ${info.value}');
  //   name = alsa.snd_rawmidi_info_get_name(info.value);
  //   print('name ${stringFromNative(name)}');
  //   name = alsa.snd_rawmidi_info_get_subdevice_name(info.value);
  //   print('subdevice name ${stringFromNative(name)}');
  //   calloc.free(info);
  //   // calloc.free(name);
  // }

  /// Starts scanning for BLE MIDI devices.
  ///
  /// Found devices will be included in the list returned by [devices].
  Future<void> startScanningForBluetoothDevices() async {}

  /// Stops scanning for BLE MIDI devices.
  void stopScanningForBluetoothDevices() {}

  /// Connects to the device.
  @override
  void connectToDevice(MidiDevice device) {
    print('connect to $device');

    var linuxDevice = device as LinuxMidiDevice;
    linuxDevice.connect().then((success) {
      if (success) {
        _connectedDevices[device.id] = device;
        _setupStreamController.add("deviceConnected");
      } else {
        print("failed to connect $linuxDevice");
      }
    });
  }

  /// Opens a port on a connected device.
  @override
  void openPortsOnDevice(MidiDevice device, List<MidiPort> ports) {
    print('open ports');
  }

  /// Disconnects from the device.
  @override
  void disconnectDevice(MidiDevice device, {bool remove = true}) {
    if (_connectedDevices.containsKey(device.id)) {
      var linuxDevice = device as LinuxMidiDevice;
      linuxDevice.disconnect();
      if (remove) _connectedDevices.remove(device.id);
    }
  }

  @override
  void teardown() {
    print("teardown");

    _connectedDevices.values.forEach((device) {
      disconnectDevice(device, remove: false);
    });
    _connectedDevices.clear();
  }

  /// Sends data to the currently connected device.wmidi hardware driver name
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    // print("send $data through buffer");

    final buffer = calloc<Uint8>();
    for (var i = 0; i < data.length; i++) {
      buffer[i] = data[i];
    }
    // final voidBuffer = buffer.cast<Void>();

    _connectedDevices.values.forEach((device) {
      // print("send to $device");
      device.send(buffer, data.length);
      // if (device.outPort != null) {
      //   int status;
      //   if ((status = alsa.snd_rawmidi_write(device.outPort!.value, voidBuffer, data.length)) < 0) {
      //     print('failed to write ${stringFromNative(alsa.snd_strerror(status))}');
      //   }
      // } else {
      //   print('outport is null');
      // }
    });

    calloc.free(buffer);
  }

  /// Stream firing events whenever a midi package is received.
  ///
  /// The event contains the raw bytes contained in the MIDI package.
  @override
  Stream<MidiPacket>? get onMidiDataReceived {
    return _rxStream;
  }

  /// Stream firing events whenever a change in the MIDI setup occurs.
  ///
  /// For example, when a new BLE devices is discovered.
  @override
  Stream<String>? get onMidiSetupChanged {
    return _setupStream;
  }
}
