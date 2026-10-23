//
//  AnisetteDataProvider.swift
//  AnisetteKit
//
//  Created by Magesh K on 07/09/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import CoreFoundation
import Foundation
import anisette_core

public enum AnisetteProviderStage: String, Sendable {
    case headersStarted, headersReturned
    case provisionStartStarted, provisionStartReturned
    case provisionEndStarted, provisionEndReturned
}

public protocol AnisetteDataProvider: Sendable {
    var requiresLocalLibraries: Bool { get }
    func getAnisetteHeaders(libDir: String, provisioningDir: String, identifier: [UInt8], adiPb: [UInt8]) async throws
        -> AnisetteDataResponse
    func startProvision(libDir: String, provisioningDir: String, identifier: [UInt8], spim: [UInt8]) async throws -> (
        cpim: Data, session: UInt32
    )
    func endProvision(
        libDir: String, provisioningDir: String, identifier: [UInt8], session: UInt32, ptm: [UInt8], tk: [UInt8]
    ) async throws -> Data
}

public typealias CStringPointer = UnsafeMutablePointer<CChar>

/// Clears the cached local Unicorn VM and ADI state so later calls reload libraries and provisioning identity.
public func resetLocalAnisetteEngine() {
    reset_anisette_vm_uc()
}

public struct AnisetteProviderDiagnostic: Sendable, Equatable {
    public enum Operation: String, Sendable { case headers, provisionStart, provisionEnd }
    public enum Result: String, Sendable {
        case boundaryReturned, parsed, nilResponse, invalidJSON, invalidResponse, providerError
    }
    public enum Phase: String, Sendable, CaseIterable {
        case arguments, vmAllocation, vmInitialization, libraryLoad, libraryRelocation, libraryConstructors
        case loadLibrarySymbol, loadLibrary, provisioningDirectory, setProvisioningPathSymbol, setProvisioningPath
        case setAndroidIDSymbol, setAndroidID, provisionStartSymbol, provisionStart, provisionStartOutput, exception
    }
    public let operation: Operation
    public let result: Result
    public let code: Int32
    public let nativeCode: Int32?
    public let phase: Phase?
    public init(operation: Operation, result: Result, code: Int32, nativeCode: Int32? = nil, phase: Phase? = nil) {
        self.operation = operation
        self.result = result
        self.code = code
        self.nativeCode = nativeCode
        self.phase = phase
    }
}

extension AnisetteDataProvider {
    func parseHeadersResponse(
        code: Int32, outPtr: CStringPointer?, providerName: String,
        diagnostic: (
            @Sendable (AnisetteProviderDiagnostic.Result, Int32?, AnisetteProviderDiagnostic.Phase?) -> Void
        )? = nil
    ) throws -> AnisetteDataResponse {
        let dict = try responseDictionary(
            code: code, outPtr: outPtr, providerName: providerName, diagnostic: diagnostic)
        if let err = dict["error"] as? String {
            diagnostic?(.providerError, diagnosticFields(dict).0, diagnosticFields(dict).1)
            throw AnisetteError.adiError(code: code, description: err)
        }
        do {
            let value = try AnisetteDataResponse(from: dict.compactMapValues { $0 as? String })
            diagnostic?(.parsed, nil, nil)
            return value
        } catch {
            diagnostic?(.invalidResponse, nil, nil)
            throw error
        }
    }
    func parseStartProvisionResponse(
        code: Int32, outPtr: CStringPointer?, providerName: String,
        diagnostic: (
            @Sendable (AnisetteProviderDiagnostic.Result, Int32?, AnisetteProviderDiagnostic.Phase?) -> Void
        )? = nil
    ) throws -> (cpim: Data, session: UInt32) {
        let dict = try responseDictionary(
            code: code, outPtr: outPtr, providerName: providerName, diagnostic: diagnostic)
        if let err = dict["error"] as? String {
            diagnostic?(.providerError, diagnosticFields(dict).0, diagnosticFields(dict).1)
            throw AnisetteError.adiError(code: code, description: err)
        }
        guard let cpimText = dict["cpim_base64"] as? String, let cpim = Data(base64Encoded: cpimText),
            let n = dict["session"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
            n.doubleValue.rounded(.towardZero) == n.doubleValue, let session = UInt32(exactly: n.int64Value)
        else {
            diagnostic?(.invalidResponse, nil, nil)
            throw AnisetteError.invalidResponse(reason: "Missing/invalid cpim_base64 or session")
        }
        diagnostic?(.parsed, nil, nil)
        return (cpim, session)
    }
    func parseEndProvisionResponse(
        code: Int32, outPtr: CStringPointer?, providerName: String,
        diagnostic: (
            @Sendable (AnisetteProviderDiagnostic.Result, Int32?, AnisetteProviderDiagnostic.Phase?) -> Void
        )? = nil
    ) throws -> Data {
        let dict = try responseDictionary(
            code: code, outPtr: outPtr, providerName: providerName, diagnostic: diagnostic)
        if let err = dict["error"] as? String {
            diagnostic?(.providerError, diagnosticFields(dict).0, diagnosticFields(dict).1)
            throw AnisetteError.adiError(code: code, description: err)
        }
        guard let text = dict["adi_pb_base64"] as? String, let data = Data(base64Encoded: text) else {
            diagnostic?(.invalidResponse, nil, nil)
            throw AnisetteError.invalidResponse(reason: "Missing/invalid adi_pb_base64")
        }
        diagnostic?(.parsed, nil, nil)
        return data
    }
    private func responseDictionary(
        code: Int32, outPtr: CStringPointer?, providerName: String,
        diagnostic: (@Sendable (AnisetteProviderDiagnostic.Result, Int32?, AnisetteProviderDiagnostic.Phase?) -> Void)?
    ) throws -> [String: Any] {
        guard let ptr = outPtr else {
            diagnostic?(.nilResponse, nil, nil)
            throw AnisetteError.loaderFailed(reason: "\(providerName) loader returned nil (code: \(code))")
        }
        let data = Data(String(cString: ptr).utf8)
        guard let any = try? JSONSerialization.jsonObject(with: data), let dict = any as? [String: Any] else {
            diagnostic?(.invalidJSON, nil, nil)
            throw AnisetteError.invalidResponse(reason: "Bad JSON from \(providerName)")
        }
        let (native, phase) = diagnosticFields(dict)
        if code != 0 && (dict["error"] as? String) == nil {
            diagnostic?(.providerError, native, phase)
            throw AnisetteError.loaderFailed(reason: "\(providerName) returned code \(code)")
        }
        return dict
    }
    private func diagnosticFields(_ dict: [String: Any]) -> (Int32?, AnisetteProviderDiagnostic.Phase?) {
        var native: Int32?
        var phase: AnisetteProviderDiagnostic.Phase?
        if let n = dict["native_code"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
            String(cString: n.objCType).contains("i") || String(cString: n.objCType).contains("l")
                || String(cString: n.objCType).contains("q")
        {
            native = Int32(exactly: n.int64Value)
        }
        if let s = dict["diagnostic_phase"] as? String { phase = AnisetteProviderDiagnostic.Phase(rawValue: s) }
        return (native, phase)
    }
}

public struct UnicornAnisetteDataProvider: AnisetteDataProvider {
    public var requiresLocalLibraries: Bool { true }
    private let onStage: (@Sendable (AnisetteProviderStage) -> Void)?
    public let onDiagnostic: (@Sendable (AnisetteProviderDiagnostic) -> Void)?
    public init(
        onStage: (@Sendable (AnisetteProviderStage) -> Void)? = nil,
        onDiagnostic: (@Sendable (AnisetteProviderDiagnostic) -> Void)? = nil
    ) {
        self.onStage = onStage
        self.onDiagnostic = onDiagnostic
    }
    public func getAnisetteHeaders(libDir: String, provisioningDir: String, identifier: [UInt8], adiPb: [UInt8]) throws
        -> AnisetteDataResponse
    {
        var outPtr: CStringPointer? = nil
        onStage?(.headersStarted)
        let res = get_anisette_headers_uc(libDir, provisioningDir, identifier, adiPb, UInt32(adiPb.count), &outPtr)
        onDiagnostic?(.init(operation: .headers, result: .boundaryReturned, code: res))
        defer { if let p = outPtr { free_c_string(p) } }
        let value = try parseHeadersResponse(
            code: res, outPtr: outPtr, providerName: "Unicorn",
            diagnostic: { r, n, p in
                self.onDiagnostic?(.init(operation: .headers, result: r, code: res, nativeCode: n, phase: p))
            })
        onStage?(.headersReturned)
        return value
    }
    public func startProvision(libDir: String, provisioningDir: String, identifier: [UInt8], spim: [UInt8]) throws -> (
        cpim: Data, session: UInt32
    ) {
        var outPtr: CStringPointer? = nil
        onStage?(.provisionStartStarted)
        let res = start_provision_uc(libDir, provisioningDir, identifier, spim, UInt32(spim.count), &outPtr)
        onDiagnostic?(.init(operation: .provisionStart, result: .boundaryReturned, code: res))
        defer { if let p = outPtr { free_c_string(p) } }
        let value = try parseStartProvisionResponse(
            code: res, outPtr: outPtr, providerName: "Unicorn",
            diagnostic: { r, n, p in
                self.onDiagnostic?(.init(operation: .provisionStart, result: r, code: res, nativeCode: n, phase: p))
            })
        onStage?(.provisionStartReturned)
        return value
    }
    public func endProvision(
        libDir: String, provisioningDir: String, identifier: [UInt8], session: UInt32, ptm: [UInt8], tk: [UInt8]
    ) throws -> Data {
        var outPtr: CStringPointer? = nil
        onStage?(.provisionEndStarted)
        let res = end_provision_uc(
            libDir, provisioningDir, identifier, session, ptm, UInt32(ptm.count), tk, UInt32(tk.count), &outPtr)
        onDiagnostic?(.init(operation: .provisionEnd, result: .boundaryReturned, code: res))
        defer { if let p = outPtr { free_c_string(p) } }
        let value = try parseEndProvisionResponse(
            code: res, outPtr: outPtr, providerName: "Unicorn",
            diagnostic: { r, n, p in
                self.onDiagnostic?(.init(operation: .provisionEnd, result: r, code: res, nativeCode: n, phase: p))
            })
        onStage?(.provisionEndReturned)
        return value
    }
}

#if os(macOS)
    public struct NativeAnisetteDataProvider: AnisetteDataProvider {
        public var requiresLocalLibraries: Bool { true }

        public init() {}

        public func getAnisetteHeaders(libDir: String, provisioningDir: String, identifier: [UInt8], adiPb: [UInt8])
            throws -> AnisetteDataResponse
        {
            var outPtr: CStringPointer? = nil
            let res = get_anisette_headers_c(libDir, provisioningDir, identifier, adiPb, UInt32(adiPb.count), &outPtr)
            defer { if let p = outPtr { free_c_string(p) } }
            return try parseHeadersResponse(code: res, outPtr: outPtr, providerName: "Native")
        }

        public func startProvision(libDir: String, provisioningDir: String, identifier: [UInt8], spim: [UInt8]) throws
            -> (cpim: Data, session: UInt32)
        {
            var outPtr: CStringPointer? = nil
            let res = start_provision_c(libDir, provisioningDir, identifier, spim, UInt32(spim.count), &outPtr)
            defer { if let p = outPtr { free_c_string(p) } }
            return try parseStartProvisionResponse(code: res, outPtr: outPtr, providerName: "Native")
        }

        public func endProvision(
            libDir: String, provisioningDir: String, identifier: [UInt8], session: UInt32, ptm: [UInt8], tk: [UInt8]
        ) throws -> Data {
            var outPtr: CStringPointer? = nil
            let res = end_provision_c(
                libDir, provisioningDir, identifier, session, ptm, UInt32(ptm.count), tk, UInt32(tk.count), &outPtr)
            defer { if let p = outPtr { free_c_string(p) } }
            return try parseEndProvisionResponse(code: res, outPtr: outPtr, providerName: "Native")
        }
    }
#endif
