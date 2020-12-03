//
//  Gromsson+ExecuteAll.swift
//  Gormsson
//
//  Created by Mac on 20/11/2020.
//  Copyright © 2020 Loïc GRIFFIE. All rights reserved.
//

import CoreBluetooth
import Nevanlinna

extension Gormsson {
    /// ActionType is the possible type of the characteristic.
    public enum ActionType { // No notify or connect/disconnect
        case read
        case write(value: DataConvertible, type: CBCharacteristicWriteType = .withResponse)
    }

    /// Action is the action to proceed.
    public struct Action {
        var characteristic: CharacteristicProtocol
        var type: ActionType

        public init(_ characteristic: CharacteristicProtocol, for type: ActionType = .read) {
            self.characteristic = characteristic
            self.type = type
        }

        public init(_ characteristic: GattCharacteristic, for type: ActionType = .read) {
            self.characteristic = characteristic.characteristic
            self.type = type
        }
    }

    public struct ActionResult {
        var peripheral: CBPeripheral
        var data: DataInitializable
        var characteristic: CharacteristicProtocol
    }

    /// Start to connect each peripheral.
    /// Then **execute** all the characteristics in array order, return all the results.
    /// And then disconnect all peripherals.
    /// At the end of all requests (or if timeout is reach), call completion.
    /// Result param will trigger each success or failure, and completion will be trigger just once.
    public func executeAll(_ actions: [Action],
                           on peripherals: [CBPeripheral],
                           timeout: Int = 30,
                           result: ((Result<ActionResult, Error>) -> Void)? = nil,
                           completion: ((Error?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let downloadGroup = DispatchGroup()

            peripherals.forEach { peripheral in
                downloadGroup.enter()

                self?.manager.connect(peripheral, success: {
                    // Everything is fine, wait to be ready
                }, failure: { error in
                    if let error = error {
                        result?(.failure(error))
                    }
                }, didReadyHandler: {
                    self?.execute(actions: actions, on: peripheral, result: { currentResult in
                        if case let .failure(error) = currentResult {
                            result?(.failure(error))
                        } else if case let .success(value) = currentResult {
                            result?(.success(value))
                        }
                    }, completion: { error in
                        if let error = error {
                            result?(.failure(error))
                        }

                        self?.disconnect(peripheral)
                    })
                }, didDisconnectHandler: { error in
                    if let error = error {
                        result?(.failure(error))
                    }

                    downloadGroup.leave()
                })
            }

            // Wait for the timeout, if needed
            let result = downloadGroup.wait(timeout: .now() + .seconds(timeout))

            DispatchQueue.main.async {
                guard result == .timedOut else {
                    completion?(nil) // Completed with success
                    return
                }

                completion?(GormssonError.timedOut)
            }
        }
    }

    // MARK: - Private functions

    private func execute(at index: Int = 0,
                         actions: [Action],
                         on peripheral: CBPeripheral,
                         result: @escaping (Result<ActionResult, Error>) -> Void,
                         completion: ((Error?) -> Void)? = nil) {
        guard index < actions.count else {
            completion?(nil)
            return
        }
        let action = actions[index]
        let block = { [weak self] (currentResult: Result<DataInitializable, Error>) in
            if case let .failure(error) = currentResult {
                result(.failure(error))
            } else if case let .success(value) = currentResult {
                result(.success(ActionResult(peripheral: peripheral,
                                             data: value,
                                             characteristic: action.characteristic)))
            }
            self?.execute(at: index + 1, actions: actions, on: peripheral, result: result, completion: completion)
        }

        switch action.type {
        case .read:
            manager.read(action.characteristic, on: peripheral, result: block)
        case .write(let value, let type):
            manager.write(action.characteristic, on: peripheral, value: value, type: type, result: block)
        }
    }
}
