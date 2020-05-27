//
//  ConnectViewCoordinator.swift
//  This file is part of the Salt Edge Authenticator distribution
//  (https://github.com/saltedge/sca-authenticator-ios)
//  Copyright © 2019 Salt Edge Inc.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, version 3 or later.
//
//  This program is distributed in the hope that it will be useful, but
//  WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <http://www.gnu.org/licenses/>.
//
//  For the additional permissions granted for Salt Edge Authenticator
//  under Section 7 of the GNU General Public License see THIRD_PARTY_NOTICES.md
//

import UIKit
import SEAuthenticator

final class ConnectViewCoordinator: Coordinator {
    private let rootViewController: UIViewController

    private lazy var webViewController = ConnectorWebViewController()
    private var connectViewController = ConnectViewController()
    private var connectionId: String?
    private var connection: Connection?
    private let connectionType: ConnectionType
    private let deepLinkUrl: URL?

    init(rootViewController: UIViewController,
         connectionType: ConnectionType,
         deepLinkUrl: URL? = nil,
         connectionId: String? = nil) {
        self.deepLinkUrl = deepLinkUrl
        self.rootViewController = rootViewController
        self.connectionType = connectionType
    }

    func start() {
        switch connectionType {
        case .reconnect: reconnectConnection()
        case .connect(let metadata): check(qrMetadata: metadata)
        case .deepLink:
            if let url = deepLinkUrl {
                handleQr(url: url)
            } else {
//                check()
            }
        case .firstConnect(let metadata):
            if let qrUrl = URL(string: metadata), SEConnectHelper.isValid(deepLinkUrl: qrUrl) {
                self.fetchConfiguration(deepLinkUrl: qrUrl)
            } else {
                self.connectViewController.dismiss(animated: true)
            }
        }

        rootViewController.present(
            UINavigationController(rootViewController: connectViewController),
            animated: true
        )
    }

    func stop() {}

    private func fetchConfiguration(deepLinkUrl: URL) {
        guard let configurationUrl = SEConnectHelper.сonfiguration(from: deepLinkUrl) else { return }

        let connectQuery = SEConnectHelper.connectQuery(from: deepLinkUrl)

        showWebViewController()
        createNewConnection(from: configurationUrl, with: connectQuery)
    }

    private func check(qrMetadata: String) {
        checkInternetConnection()

        if let qrUrl = URL(string: qrMetadata), SEConnectHelper.isValid(deepLinkUrl: qrUrl) {
            handleQr(url: qrUrl)
        } else {
            connectViewController.dismiss(animated: true)
        }
    }

    private func handleQr(url: URL) {
        if let actionGuid = SEConnectHelper.actionGuid(from: url),
            let connectUrl = SEConnectHelper.connectUrl(from: url) {
            guard ConnectionsCollector.activeConnections.count > 0 else {
                finishConnectWithError(l10n(.noActiveConnection))
                return
            }

            connectViewController.title = l10n(.newAction)

            let connections = ConnectionsCollector.activeConnections(by: connectUrl)

            if connections.count > 1 {
                presentConnectionPicker(with: connections, actionGuid: actionGuid, connectUrl: connectUrl, qrUrl: url)
            } else if connections.count == 1 {
                guard let connection = connections.first else { return }

                submitAction(for: connection, connectUrl: connectUrl, actionGuid: actionGuid, qrUrl: url)
            } else {
                dismissConnectWithError(l10n(.noSuitableConnection))
            }
        } else {
            fetchConfiguration(deepLinkUrl: url)
        }
    }

    private func presentConnectionPicker(with connections: [Connection], actionGuid: GUID, connectUrl: URL, qrUrl: URL) {
        let pickerVc = ConnectionPickerViewController(connections: connections)
        pickerVc.modalPresentationStyle = .fullScreen

        connectViewController.title = l10n(.selectConnection)
        connectViewController.add(pickerVc)

        pickerVc.selectedConnection = { connection in
            pickerVc.remove()
            self.connectViewController.title = l10n(.newAction)
            self.submitAction(for: connection, connectUrl: connectUrl, actionGuid: actionGuid, qrUrl: qrUrl)
        }
        pickerVc.cancelPressedClosure = {
            self.rootViewController.dismiss(animated: true)
        }
    }

    private func submitAction(for connection: Connection, connectUrl: URL, actionGuid: GUID, qrUrl: URL) {
        let actionData = SEActionRequestData(
            url: connectUrl,
            connectionGuid: connection.guid,
            accessToken: connection.accessToken,
            appLanguage: UserDefaultsHelper.applicationLanguage,
            guid: actionGuid
        )

        SEActionManager.submitAction(
            data: actionData,
            onSuccess: { [weak self] response in
                self?.handleActionResponse(response, qrUrl: qrUrl)
            },
            onFailure: { [weak self] _ in
                DispatchQueue.main.async {
                    self?.finishConnectWithError(l10n(.actionError))
                }
            }
        )
    }

    private func handleActionResponse(_ response: SESubmitActionResponse, qrUrl: URL) {
        if let connectionId = response.connectionId,
            let authorizationId = response.authorizationId {
            AppDelegate.main.applicationCoordinator?.showAuthorizations(
                connectionId: connectionId,
                authorizationId: authorizationId
            )
        } else {
            if let returnTo = SEConnectHelper.returnToUrl(from: qrUrl) {
                UIApplication.shared.open(returnTo)
            } else {
                connectViewController.dismiss(animated: true)
            }

//            connectViewController.showCompleteView(
//                with: .success,
//                title: l10n(.instantActionSuccessMessage),
//                description: l10n(.instantActionSuccessDescription),
//                completion: {
//                    if let returnTo = SEConnectHelper.returnToUrl(from: qrUrl) {
//                        UIApplication.shared.open(returnTo)
//                    }
//                }
//            )
        }
    }

    private func createNewConnection(from configurationUrl: URL, with connectQuery: String?) {
        ConnectionsInteractor.createNewConnection(
            from: configurationUrl,
            with: connectQuery,
            success: { [weak self] connection, accessToken in
                self?.connection = connection
                self?.finishConnectWithSuccess(accessToken: accessToken)
            },
            redirect: { [weak self]  connection, connectUrl in
                self?.connection = connection
                self?.webViewController.startLoading(with: connectUrl)
            },
            failure: { [weak self] error in
                self?.dismissConnectWithError(error)
            }
        )
    }

    private func showWebViewController() {
        webViewController.delegate = self
        connectViewController.add(webViewController)
        connectViewController.title = connectionType == .reconnect ? l10n(.reconnect) : l10n(.newConnection)
    }

    private func reconnectConnection() {
        guard let connectionId = connectionId, let connection = ConnectionsCollector.with(id: connectionId) else { return }

        ConnectionsInteractor.submitConnection(
            for: connection,
            connectQuery: nil,
            success: { [weak self] connection, accessToken in
                self?.connection = connection
                self?.finishConnectWithSuccess(accessToken: accessToken)
            },
            redirect: { [weak self]  connection, connectUrl in
                self?.connection = connection
                self?.webViewController.startLoading(with: connectUrl)
            },
            failure: { [weak self] error in
                self?.dismissConnectWithError(error)
            }
        )
    }

    private func checkInternetConnection() {
        guard ReachabilityManager.shared.isReachable else {
            self.connectViewController.showInfoAlert(
                withTitle: l10n(.noInternetConnection),
                message: l10n(.pleaseTryAgain),
                actionTitle: l10n(.ok),
                completion: {
                    self.connectViewController.dismiss(animated: true)
                }
            )
            return
        }
    }
}

// MARK: - ConnectorWebViewControllerDelegate
extension ConnectViewCoordinator: ConnectorWebViewControllerDelegate {
    func connectorConfirmed(url: URL, accessToken: AccessToken) {
        finishConnectWithSuccess(accessToken: accessToken)
    }

    func showError(_ error: String) {
        finishConnectWithError(error)
    }
}

// MARK: - ConnectViewCoordinator: Finish
extension ConnectViewCoordinator {
    func finishConnectWithSuccess(accessToken: AccessToken) {
        guard let connection = connection else { return }

        ConnectionRepository.setAccessTokenAndActive(connection, accessToken: accessToken)
        ConnectionRepository.save(connection)

        webViewController.remove()
        connectViewController.navigationItem.leftBarButtonItem = nil
        let successTitleTemplate = l10n(.connectedSuccessfullyTitle)
        connectViewController.showCompleteView(with: .success, title: String(format: successTitleTemplate, connection.name))
    }

    func finishConnectWithError(_ error: String) {
        connectViewController.showCompleteView(with: .fail, title: error, description: l10n(.tryAgain))
    }

    func dismissConnectWithError(_ error: String) {
        connectViewController.dismiss(
            animated: true,
            completion: {
                self.rootViewController.present(message: error, style: .error)
            }
        )
    }
}
