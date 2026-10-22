import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ADILoaderContractTests(unittest.TestCase):
    def test_explicit_hooks_match_diagnostic_table(self):
        native = (ROOT / 'Packages/AnisetteKit/Native/Loader/elf_loader_emulator.cpp').read_text()
        router = native.rsplit('static void import_callback_router', 1)[1].split('static uint64_t vm_resolve_symbol', 1)[0]
        actual = set(re.findall(r'name == "([^"]+)"', router))
        policy = (ROOT / 'Sources/EiliStore/ADILibraryCompatibility.swift').read_text()
        declared = re.search(r'static let handledImports: Set<String> = \[(.*?)\]', policy, re.S).group(1)
        self.assertEqual(actual, set(re.findall(r'"([^"]+)"', declared)))
        self.assertNotIn('pthread_create', actual)

    def test_six_required_entrypoints_exclude_optional_cleanup(self):
        native = (ROOT / 'Packages/AnisetteKit/Native/anisette_base.h').read_text().split('struct ADISymbols', 1)[1]
        fields = dict(re.findall(r'const char\*\s+(\w+)\s*=\s*"([^"]+)"', native))
        names = ['set_android_id', 'set_provisioning_path', 'load_library', 'otp_request', 'provisioning_start', 'provisioning_end']
        policy = (ROOT / 'Sources/EiliStore/ADILibraryCompatibility.swift').read_text()
        declared = re.search(r'static let requiredEntryPoints: Set<String> = \[(.*?)\]', policy, re.S).group(1)
        self.assertEqual({fields[n] for n in names}, set(re.findall(r'"([^"]+)"', declared)))

    def test_native_layout_gate_precedes_vm_allocation(self):
        native = (ROOT / 'Packages/AnisetteKit/Native/anisette_core_uc.cpp').read_text()
        function = native.split('static bool setup_vm_and_adi', 1)[1].split('// C ABI wrappers', 1)[0]
        self.assertLess(function.index('std::string modern_entry'), function.index('new (std::nothrow) EmulatorVM'))
        gate = function.split('std::string modern_entry', 1)[1].split('if (!g_shared_vm)', 1)[0]
        self.assertIn('libstoreapi.so', gate)
        self.assertIn('return false;', gate)
        self.assertIn('does not implement', gate)


if __name__ == '__main__':
    unittest.main()
