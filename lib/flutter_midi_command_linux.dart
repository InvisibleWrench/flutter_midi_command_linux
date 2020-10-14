import 'dart:async';
import 'dart:ffi';
import 'package:ffi/ffi.dart';

import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'package:meta/meta.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';

const SND_RAWMIDI_STREAM_OUTPUT = 0;
const SND_RAWMIDI_STREAM_INPUT = 1;
const SND_RAWMIDI_APPEND = 0x0001;
const SND_RAWMIDI_NONBLOCK = 0x0002;
const SND_RAWMIDI_SYNC = 0x0004;

typedef snd_strerror = Pointer<Utf8> Function(Int8 errornum);
typedef StrError = Pointer<Utf8> Function(int errornum);

typedef snd_card_next = Int32 Function(Pointer<Int32> cardNumber);
typedef CardNext = int Function(Pointer<Int32> cardNumber);

typedef snd_card_get_name = Int32 Function(
    Int32 cardNumber, Pointer<Utf8> name);
typedef CardGetName = int Function(int cardNumber, Pointer<Utf8> name);

typedef snd_card_get_long_name = Int32 Function(
    Int32 cardNumber, Pointer<Utf8> name);
typedef CardGetLongName = int Function(int cardNumber, Pointer<Utf8> name);

typedef snd_ctl_open = Int32 Function(
    Pointer ctlp, Pointer<Utf8> name, Int8 mode);
typedef CtlOpen = int Function(
    Pointer<Int32> ctlp, Pointer<Utf8> name, int mode);

typedef snd_ctl_rawmidi_next_device = Int32 Function(
    Pointer<Int32> ctl, Pointer<Int32> device);
typedef CtlRawmidiNextDevice = int Function(
    Pointer<Int32> ctl, Pointer<Int32> device);

typedef snd_ctl_rawmidi_info = Int32 Function(
    Pointer<Int32> ctl, Pointer<Int32> info);
typedef CtlRawmidiInfo = int Function(Pointer<Int32> ctl, Pointer<Int32> info);

typedef snd_rawmidi_info_get_name = Pointer<Utf8> Function(Pointer<Int32> info);
typedef RawmidiInfoGetName = Pointer<Utf8> Function(Pointer<Int32> info);

typedef snd_rawmidi_open = Int32 Function(Pointer<Int32> inMidi,
    Pointer<Int32> outMidi, Pointer<Utf8> name, Int8 mode);
typedef RawMIDIOpen = int Function(Pointer<Int32> inMidi,
    Pointer<Int32> outMidi, Pointer<Utf8> name, int mode);

class FlutterMidiCommandLinux extends MidiCommandPlatform {
  StreamController<Uint8List> _rxStreamController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> _rxStream = StreamController<Uint8List>.broadcast().stream;
  StreamController<String> _setupStreamController =
      StreamController<String>.broadcast();
  Stream<String> _setupStream;

  Pointer<Utf8> port_name;
  Pointer<Int32> in_port;
  Pointer<Int32> out_port;

  Function strError;
  Function cardNext;
  Function cardGetName;
  Function cardGetLongName;
  Function ctlOpen;
  Function ctlRawmidiNextDevice;
  Function ctlRawmidiInfo;
  Function rawmidiInfoGetName;

  /// A constructor that allows tests to override the window object used by the plugin.
  FlutterMidiCommandLinux() {
    in_port = allocate();
    out_port = allocate();
    port_name = Utf8.toUtf8("hw:1,0,0");

    // print('in $in_port out $out_port name $port_name');

    final libalsa = DynamicLibrary.open("libasound.so.2");

    strError = libalsa.lookupFunction<snd_strerror, StrError>('snd_strerror');
    cardNext = libalsa.lookupFunction<snd_card_next, CardNext>('snd_card_next');
    cardGetName = libalsa
        .lookupFunction<snd_card_get_name, CardGetName>('snd_card_get_name');
    cardGetLongName =
        libalsa.lookupFunction<snd_card_get_long_name, CardGetLongName>(
            'snd_card_next');
    ctlOpen = libalsa.lookupFunction<snd_ctl_open, CtlOpen>('snd_ctl_open');
    ctlRawmidiNextDevice = libalsa.lookupFunction<snd_ctl_rawmidi_next_device,
        CtlRawmidiNextDevice>('snd_ctl_rawmidi_next_device');
    ctlRawmidiInfo =
        libalsa.lookupFunction<snd_ctl_rawmidi_info, CtlRawmidiInfo>(
            'snd_ctl_rawmidi_info');
    rawmidiInfoGetName =
        libalsa.lookupFunction<snd_rawmidi_info_get_name, RawmidiInfoGetName>(
            'snd_rawmidi_info_get_name');

    // final rawMIDIOpen = libalsa
    //     .lookupFunction<snd_rawmidi_open, RawMIDIOpen>('snd_rawmidi_open');
    // int result =
    //     rawMIDIOpen(in_port, out_port, port_name, SND_RAWMIDI_NONBLOCK);
    // print('Result: $result ${statusMessage(result)}');
  }

  String statusMessage(int status) {
    return Utf8.fromUtf8(strError(status));
  }

  /// The linux implementation of [MidiCommandPlatform]
  ///
  /// This class implements the `package:flutter_midi_command_platform_interface` functionality for linux
  static void register() {
    print("register FlutterMidiCommandLinux");
    MidiCommandPlatform.instance = FlutterMidiCommandLinux();
  }

  @override
  Future<List<MidiDevice>> get devices async {
    _printMidiPorts();
    // _printCardList();
    return List<MidiDevice>();
    // JsObject i = new JsObject.fromBrowserObject(object)
    // _access.inputs.forEach((key, value) {
    //   print("input key ${key} ${value}");
    //   // print( "Input port [type:'${element.type}'] id:'${element.id}' manufacturer:'${element.manufacturer}' name:'${element.name}' version:'${element.version}'");
    //   // element.value.onMidiMessage.listen(_handleMidiIn);
    //   // html.MidiPort inPort = element as html.MidiPort;
    //   // value.on['midimessage'].listen(_handleMidiIn);
    // });

    // _access.outputs.forEach((key, value) {
    //   print("output ${key} ${value}");FlutterMidiCommandLinux
    // });

    // var devs = await _methodChannel.invokeMethod('getDevices');
    // return devs.map<MidiDevice>((m) {
    //   var map = m.cast<String, Object>();
    //   return MidiDevice(map["id"], map["name"], map["type"], map["connected"] == "true");
    // }).toList();
  }

  void _printCardList() {
    int status;
    var card = allocate<Int32>(count: 1);
    card.elementAt(0).value = -1;
    Pointer<Utf8> longname = nullptr;
    Pointer<Utf8> shortname = nullptr;

    if ((status = cardNext(card)) < 0) {
      print('error: cannot determine card number $card ${strError(status)}');
      return;
    }
    print('status $status');
    if (card.value < 0) {
      print('error: no sound cards found');
      return;
    }

    while (card.value >= 0) {
      print("card ${card.value}");
      if ((status = cardGetName(card, shortname)) < 0) {
        print(
            'error: cannot determine card shortname $card ${strError(status)}');
        break;
      }
      print('status $status');
      // if ((status = cardGetLongName(card, longname)) < 0) {
      //   print(
      //       'error: cannot determine card longname $card ${strError(status)}');
      //   break;
      // }
      print('status $status');
      print("card shortname ${Utf8.fromUtf8(shortname)}");
      // print("card longname ${Utf8.fromUtf8(longname)}");
      if ((status = cardNext(card)) < 0) {
        print('error: cannot determine card number $card ${strError(status)}');
        return;
      }
    }
  }

  void _printMidiPorts() {
    int status;
    var card = allocate<Int32>(count: 1);
    card.elementAt(0).value = -1;

    if ((status = cardNext(card)) < 0) {
      print('error: cannot determine card number $card ${strError(status)}');
      return;
    }
    if (card.value < 0) {
      print('error: no sound cards found');
      return;
    }

    print('device:');
    while (card.value >= 0) {
      _listMidiDevicesOnCard(card.value);

      if ((status = cardNext(card)) < 0) {
        print(
            'error: cannot determine next card number $card ${strError(status)}');
        break;
      }
    }
    print('end');
  }

  void _listMidiDevicesOnCard(int card) {
    Pointer<Int32> ctl = allocate<Int32>(count: 1);
    Pointer<Utf8> name = Utf8.toUtf8("hw:$card");
    Pointer<Int32> device = allocate<Int32>(count: 1);
    device.elementAt(0).value = -1;
    int status;

    print('device on card ${Utf8.fromUtf8(name)}');
    if ((status = ctlOpen(ctl, name, 0)) < 0) {
      print(
          'error: cannot open control for card number $card ${strError(status)}');
      return;
    }

    do {
      print("ctl $ctl device $device");
      status = ctlRawmidiNextDevice(ctl, device);
      print("status $status");
      if (status < 0) {
        print(
            'error: cannot determine device number ${device.value} ${strError(status)}');
        break;
      }
      if (device.value >= 0) {
        _listSubdeviceInfo(ctl, card, device.value);
      }
    } while (device.value > 0);
  }

  void _listSubdeviceInfo(Pointer ctl, int card, int device) {
    Pointer<Int32> info = allocate<Int32>(count: 1);
    Pointer<Utf8> name = allocate();

    int status = ctlRawmidiInfo(ctl, info);
    if (status < 0) {
      print('error: cannot get device info ${strError(status)}');
      return;
    }
    print('info ${info.value}');
    name = rawmidiInfoGetName(info);
    print('name ${Utf8.fromUtf8(name)}');
  }

  /// Starts scanning for BLE MIDI devices.
  ///
  /// Found devices will be included in the list returned by [devices].
  Future<void> startScanningForBluetoothDevices() async {}

  /// Stops scanning for BLE MIDI devices.
  void stopScanningForBluetoothDevices() {}

  /// Connects to the device.
  @override
  void connectToDevice(MidiDevice device) {
    // _methodChannel.invokeMethod('connectToDevice', device.toDictionary);
  }

  /// Disconnects from the device.
  @override
  void disconnectDevice(MidiDevice device) {
    // _methodChannel.invokeMethod('disconnectDevice', device.toDictionary);
  }

  @override
  void teardown() {
    // _methodChannel.invokeMethod('teardown');
  }

  /// Sends data to the currently connected device.wmidi hardware driver name
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  @override
  void sendData(Uint8List data) {
    print("send $data through method channel");
    // _methodChannel.invokeMethod('sendData', data);
  }

  /// Stream firing events whenever a midi package is received.
  ///
  /// The event contains the raw bytes contained in the MIDI package.
  @override
  Stream<Uint8List> get onMidiDataReceived {
    print("get on midi data");
    // _rxStream ??= _rxChannel.receiveBroadcastStream().map<Uint8List>((d) {
    //   return Uint8List.fromList(List<int>.from(d));
    // });
    _rxStream ??= _rxStreamController.stream;
    return _rxStream;
  }

  /// Stream firing events whenever a change in the MIDI setup occurs.
  ///
  /// For example, when a new BLE devices is discovered.
  @override
  Stream<String> get onMidiSetupChanged {
    _setupStream ??= _setupStreamController.stream;
    return _setupStream;
  }
}
