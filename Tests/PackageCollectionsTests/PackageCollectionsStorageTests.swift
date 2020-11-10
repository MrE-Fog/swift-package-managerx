/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

@testable import PackageCollections
import TSCBasic
import TSCTestSupport
import XCTest

class PackageCollectionsStorageTests: XCTestCase {
    func testHappyCase() throws {
        try testWithTemporaryDirectory { tmpPath in
            let path = tmpPath.appending(component: "test.db")
            let storage = SQLitePackageCollectionsStorage(path: path)
            defer { XCTAssertNoThrow(try storage.close()) }

            let mockSources = makeMockSources()
            try mockSources.forEach { source in
                XCTAssertThrowsError(try tsc_await { callback in storage.get(identifier: .init(from: source), callback: callback) }, "expected error", { error in
                    XCTAssert(error is NotFoundError, "Expected NotFoundError")
                })
            }

            let mockCollections = makeMockCollections(count: 50)
            try mockCollections.forEach { collection in
                _ = try tsc_await { callback in storage.put(collection: collection, callback: callback) }
            }

            try mockCollections.forEach { collection in
                let retVal = try tsc_await { callback in storage.get(identifier: collection.identifier, callback: callback) }
                XCTAssertEqual(retVal.identifier, collection.identifier)
            }

            do {
                let list = try tsc_await { callback in storage.list(callback: callback) }
                XCTAssertEqual(list.count, mockCollections.count)
            }

            do {
                let count = Int.random(in: 1 ..< mockCollections.count)
                let list = try tsc_await { callback in storage.list(identifiers: mockCollections.prefix(count).map { $0.identifier }, callback: callback) }
                XCTAssertEqual(list.count, count)
            }

            do {
                _ = try tsc_await { callback in storage.remove(identifier: mockCollections.first!.identifier, callback: callback) }
                let list = try tsc_await { callback in storage.list(callback: callback) }
                XCTAssertEqual(list.count, mockCollections.count - 1)
            }

            XCTAssertThrowsError(try tsc_await { callback in storage.get(identifier: mockCollections.first!.identifier, callback: callback) }, "expected error", { error in
                XCTAssert(error is NotFoundError, "Expected NotFoundError")
            })

            guard case .path(let storagePath) = storage.location else {
                return XCTFail("invalid location \(storage.location)")
            }

            XCTAssertTrue(storage.fileSystem.exists(storagePath), "expected file to be written")
        }
    }

    func testFileDeleted() throws {
        try testWithTemporaryDirectory { tmpPath in
            let path = tmpPath.appending(component: "test.db")
            let storage = SQLitePackageCollectionsStorage(path: path)
            defer { XCTAssertNoThrow(try storage.close()) }

            let mockCollections = makeMockCollections()
            try mockCollections.forEach { collection in
                _ = try tsc_await { callback in storage.put(collection: collection, callback: callback) }
            }

            try mockCollections.forEach { collection in
                let retVal = try tsc_await { callback in storage.get(identifier: collection.identifier, callback: callback) }
                XCTAssertEqual(retVal.identifier, collection.identifier)
            }

            guard case .path(let storagePath) = storage.location else {
                return XCTFail("invalid location \(storage.location)")
            }

            XCTAssertTrue(storage.fileSystem.exists(storagePath), "expected file to exist at \(storagePath)")

            try storage.fileSystem.removeFileTree(storagePath)

            XCTAssertThrowsError(try tsc_await { callback in storage.get(identifier: mockCollections.first!.identifier, callback: callback) }, "expected error", { error in
                XCTAssert(error is NotFoundError, "Expected NotFoundError")
            })

            XCTAssertNoThrow(try tsc_await { callback in storage.put(collection: mockCollections.first!, callback: callback) })
            let retVal = try tsc_await { callback in storage.get(identifier: mockCollections.first!.identifier, callback: callback) }
            XCTAssertEqual(retVal.identifier, mockCollections.first!.identifier)

            XCTAssertTrue(storage.fileSystem.exists(storagePath), "expected file to exist at \(storagePath)")
        }
    }

    func testFileCorrupt() throws {
        try testWithTemporaryDirectory { tmpPath in
            let path = tmpPath.appending(component: "test.db")
            let storage = SQLitePackageCollectionsStorage(path: path)
            defer { XCTAssertNoThrow(try storage.close()) }

            let mockCollections = makeMockCollections()
            try mockCollections.forEach { collection in
                _ = try tsc_await { callback in storage.put(collection: collection, callback: callback) }
            }

            try mockCollections.forEach { collection in
                let retVal = try tsc_await { callback in storage.get(identifier: collection.identifier, callback: callback) }
                XCTAssertEqual(retVal.identifier, collection.identifier)
            }

            guard case .path(let storagePath) = storage.location else {
                return XCTFail("invalid location \(storage.location)")
            }

            try storage.close()

            XCTAssertTrue(storage.fileSystem.exists(storagePath), "expected file to exist at \(path)")
            try storage.fileSystem.writeFileContents(storagePath, bytes: ByteString("blah".utf8))

            XCTAssertThrowsError(try tsc_await { callback in storage.get(identifier: mockCollections.first!.identifier, callback: callback) }, "expected error", { error in
                XCTAssert("\(error)".contains("is not a database"), "Expected file is not a database error")
            })

            XCTAssertThrowsError(try tsc_await { callback in storage.put(collection: mockCollections.first!, callback: callback) }, "expected error", { error in
                XCTAssert("\(error)".contains("is not a database"), "Expected file is not a database error")
            })
        }
    }

    func testListLessThanBatch() throws {
        let storage = SQLitePackageCollectionsStorage(location: .memory)
        defer { XCTAssertNoThrow(try storage.close()) }

        let count = SQLitePackageCollectionsStorage.batchSize / 2
        let mockCollections = makeMockCollections(count: count)
        try mockCollections.forEach { collection in
            _ = try tsc_await { callback in storage.put(collection: collection, callback: callback) }
        }

        let list = try tsc_await { callback in storage.list(callback: callback) }
        XCTAssertEqual(list.count, mockCollections.count)
    }

    func testListNonBatching() throws {
        let storage = SQLitePackageCollectionsStorage(location: .memory)
        defer { XCTAssertNoThrow(try storage.close()) }

        let count = Int(Double(SQLitePackageCollectionsStorage.batchSize) * 2.5)
        let mockCollections = makeMockCollections(count: count)
        try mockCollections.forEach { collection in
            _ = try tsc_await { callback in storage.put(collection: collection, callback: callback) }
        }

        let list = try tsc_await { callback in storage.list(callback: callback) }
        XCTAssertEqual(list.count, mockCollections.count)
    }

    func testListBatching() throws {
        let storage = SQLitePackageCollectionsStorage(location: .memory)
        defer { XCTAssertNoThrow(try storage.close()) }

        let count = Int(Double(SQLitePackageCollectionsStorage.batchSize) * 2.5)
        let mockCollections = makeMockCollections(count: count)
        try mockCollections.forEach { collection in
            _ = try tsc_await { callback in storage.put(collection: collection, callback: callback) }
        }

        let list = try tsc_await { callback in storage.list(identifiers: mockCollections.map { $0.identifier }, callback: callback) }
        XCTAssertEqual(list.count, mockCollections.count)
    }
}
