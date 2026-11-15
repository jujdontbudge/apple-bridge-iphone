import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PROOFS = [
    ('device', ['ios/Capabilities/DeviceContext/DeviceModel.swift', 'lab/ios/DeviceProof.swift'], 'PASS 5'),
    ('motion', ['ios/Capabilities/Motion/MotionModel.swift', 'lab/ios/MotionProof.swift'], 'PASS 8'),
    ('health', ['ios/Capabilities/HealthRead/HealthCapture.swift', 'lab/ios/HealthProof.swift'], 'PASS'),
    ('health-write', ['ios/Capabilities/HealthWrite/HealthLog.swift', 'lab/ios/HealthWriteProof.swift'], 'PASS'),
    ('notifications', ['ios/Delivery/NotificationCompletion.swift', 'lab/ios/NotificationProof.swift'], 'PASS'),
    ('capture', ['ios/Capabilities/Capture/CaptureModel.swift', 'ios/App/QualificationWait.swift', 'lab/ios/CaptureProof.swift'], 'PASS 4'),
    ('alarms', ['ios/Capabilities/Alarms/AlarmCommands.swift', 'lab/iphonealarms/main.swift'], 'passed'),
    ('siri', ['ios/Capabilities/Siri/CommandIntent.swift', 'lab/iphoneintents/main.swift'], 'intent_dispatch_check: pass assertions=4'),
    ('location', ['ios/Capabilities/Location/LocationStore.swift', 'ios/App/QualificationWait.swift', 'lab/fixtures/location/LocationProof.swift'], 'location_adapter_proof=pass'),
    ('shell', ['ios/Delivery/PhoneJob.swift', 'ios/Pairing/PairingState.swift', 'ios/App/ShellModel.swift', 'lab/ios/ShellProof.swift'], None),
    ('screen-time', ['ios/ScreenTimeShared/ShieldPolicy.swift', 'lab/ios/main.swift'], 'shield_policy_pass'),
]

with tempfile.TemporaryDirectory(prefix='ab-iphone-models-') as temporary:
    for name, sources, expected in PROOFS:
        binary = Path(temporary) / name
        flags = [] if name == 'screen-time' else ['-parse-as-library']
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *flags, *sources, '-o', str(binary)], cwd=ROOT, check=True, timeout=120)
        result = subprocess.check_output([str(binary), str(Path(temporary) / (name + '.json'))], cwd=temporary, text=True, timeout=30).strip()
        if expected is None:
            checks = json.loads(result)
            if not checks or not all(value is True for value in checks.values()):
                raise RuntimeError(f'{name}: failed checks')
        elif result != expected:
            raise RuntimeError(f'{name}: unexpected proof result {result!r}')
        print(f'{name}: passed', flush=True)
print(f'{len(PROOFS)} production model proofs passed')
