import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ADILoaderContractTests(unittest.TestCase):
    def test_explicit_hooks_match_diagnostic_table(self):
        native = (ROOT / 'Packages/AnisetteKit/Native/Loader/elf_loader_emulator.cpp').read_text()
        router = native.rsplit('static void import_callback_router', 1)[1].split('static uint64_t vm_resolve_symbol', 1)[0]
        actual = set(re.findall(r'name\s*==\s*"([^"]+)"', router))
        strings = (ROOT / 'Packages/AnisetteKit/Native/Loader/android_libc_strings.h').read_text()
        actual.update(re.findall(r'name\s*==\s*"([^"]+)"', strings))
        sync = (ROOT / 'Packages/AnisetteKit/Native/Loader/android_pthread_sync.h').read_text()
        actual.update(re.findall(r'name\s*(?:==|!=)\s*"([^"]+)"', sync))
        native_table = native.split('static bool supported_guest_import', 1)[1].split('return names.count', 1)[0]
        supported = set(re.findall(r'"([^"]+)"', native_table))
        policy = (ROOT / 'Sources/EiliStore/ADILibraryCompatibility.swift').read_text()
        declared = re.search(r'static let handledImports: Set<String> = \[(.*?)\]', policy, re.S).group(1)
        self.assertEqual(actual, set(re.findall(r'"([^"]+)"', declared)))
        self.assertEqual(actual, supported)
        self.assertNotIn('pthread_create', actual)
        self.assertIn('memmove', actual)
        self.assertIn('dlerror', actual)
        self.assertIn('pthread_mutex_lock', actual)
        self.assertIn('pthread_rwlock_rdlock', actual)
        self.assertIn('dl_iterate_phdr', actual)
        self.assertNotIn('pthread_cond_wait', actual)
        self.assertNotIn('pthread_once', actual)
        fallback = router.split('// SideStore\'s unresolved-function fallback:', 1)[1]
        self.assertIn('uint64_t ret = 0;', fallback)
        self.assertIn('fallback_import_calls', fallback)
        self.assertIn('uc_reg_write(uc, UC_ARM64_REG_X0, &ret)', fallback)
        self.assertNotIn('pthread_create', supported)

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

    def test_start_provision_diagnostic_schema_is_allowlisted(self):
        native = (ROOT / 'Packages/AnisetteKit/Native/anisette_core_uc.cpp').read_text()
        phases = set(re.findall(r'diagnostic_error_json\([^;]*?,\s*"([A-Za-z]+)"', native))
        allowed = {
            'arguments', 'vmAllocation', 'vmInitialization', 'libraryLoad',
            'libraryConstructors', 'libraryRelocation', 'loadLibrarySymbol', 'loadLibrary',
            'provisioningDirectory', 'setProvisioningPathSymbol', 'setProvisioningPath',
            'setAndroidIDSymbol', 'setAndroidID', 'provisionStartSymbol',
            'provisionStart', 'provisionStartOutput', 'exception',
        }
        self.assertTrue(phases)
        self.assertLessEqual(phases, allowed)
        self.assertIn('diagnostic_phase', native)
        self.assertIn('diagnostic_error_json(ss.str(), "provisionStart", true, res)', native)
        self.assertIn('int32_t res = run_vm_procedure(vm, prov_start_ptr', native)
        self.assertNotIn('"native_code":-1000', native)
        start = native.split('static int32_t start_provision_uc_impl', 1)[1].split('static int32_t end_provision_uc_impl', 1)[0]
        for phase in ('provisionStartSymbol', 'provisionStart', 'provisionStartOutput'):
            self.assertIn('"' + phase + '"', start)
        wrapper = native.split('int32_t start_provision_uc(', 1)[1].split('int32_t end_provision_uc(', 1)[0]
        self.assertIn('C++ exception', wrapper)
        self.assertIn(r'\"diagnostic_phase\":\"exception\"', wrapper)
        self.assertNotIn('diagnostic_error_json(', wrapper)

    def test_data_name_heuristics_match_native_loader(self):
        native = (ROOT / 'Packages/AnisetteKit/Native/Loader/elf_loader_emulator.cpp').read_text()
        names = native.split('static bool guest_data_symbol_name', 1)[1].split('const AndroidSystemProperties', 1)[0]
        policy = (ROOT / 'Sources/EiliStore/ADILibraryCompatibility.swift').read_text()
        declared = policy.split('static func isSideStoreDataName', 1)[1].split('static let requiredEntryPoints', 1)[0]
        self.assertEqual(set(re.findall(r'"([^"]+)"', names)), set(re.findall(r'"([^"]+)"', declared)))
        placeholder = native.split('uint64_t EmulatorVM::register_data_import', 1)[1].split('uint64_t EmulatorVM::write_bytes', 1)[0]
        self.assertIn('const uint8_t zeros[256] = {};', placeholder)
        self.assertIn('fallback_data_imports', placeholder)
        self.assertNotIn('register_import(', placeholder)

    def test_required_import_preflight_precedes_all_constructors(self):
        native = (ROOT / 'Packages/AnisetteKit/Native/Loader/elf_loader_emulator.cpp').read_text()
        preflight = native.split('bool preflight_vm_libraries', 1)[1].split('bool run_library_constructors', 1)[0]
        self.assertIn('i < lib.symbol_count', preflight)
        self.assertIn('for (const auto &lib : vm->loaded_libraries)', preflight)
        self.assertNotIn('jmprel', preflight)
        ctors = native.split('bool run_library_constructors', 1)[1].split('uint64_t get_vm_symbol_address', 1)[0]
        self.assertLess(ctors.index('preflight_vm_libraries(vm)'), ctors.index('for (const auto &lib'))
        self.assertLess(ctors.index('preflight_vm_libraries(vm)'), ctors.index('run_vm_procedure'))
        resolver = native.split('static uint64_t vm_resolve_symbol', 1)[1].split('static void apply_vm_relocations', 1)[0]
        gate = resolver.split('if (preflight)', 1)[1].split('// Keep legacy relocation', 1)[0]
        self.assertIn('supported_guest_import(sym_name)', gate)
        self.assertIn('Unsupported required guest import before constructors', gate)
        self.assertNotIn('imported_symbols', gate)
        self.assertNotIn('register_import', gate)
        core = (ROOT / 'Packages/AnisetteKit/Native/anisette_core_uc.cpp').read_text()
        self.assertIn('refused before running any library constructors. Use remote mode.', core)

    def test_sidestore_empty_output_and_tls_policy(self):
        core = (ROOT / 'Packages/AnisetteKit/Native/anisette_core_uc.cpp').read_text()
        self.assertNotRegex(core, r'(?:adi_pb|spim|ptm|tk)_len\s*==\s*0')
        self.assertNotIn('guest_length == 0', core)
        self.assertIn('file_size >= 0', core)
        self.assertIn('if (res != 0)', core)
        native = (ROOT / 'Packages/AnisetteKit/Native/Loader/elf_loader_emulator.cpp').read_text()
        self.assertNotIn('Unsupported guest PT_TLS segment', native)
        self.assertNotIn('Unsupported guest TLS/non-function symbol type', native)
        self.assertNotIn('execution_error = "Unsupported guest relocation', native)
        self.assertIn('Ignored unimplemented guest relocation', native)
        response = (ROOT / 'Packages/AnisetteKit/Sources/AnisetteDataResponse.swift').read_text()
        self.assertIn('guard let otp = dictionary', response)
        self.assertNotIn('.isEmpty', response)


if __name__ == '__main__':
    unittest.main()
