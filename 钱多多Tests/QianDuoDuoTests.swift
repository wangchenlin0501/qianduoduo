//
//  QianDuoDuoTests.swift
//  钱多多Tests
//
//

import Foundation
import Testing
import UIKit
@testable import 钱多多

struct QianDuoDuoTests {
    @Test func paymentStatusRawValuesAreStable() async throws {
        #expect(PaymentStatus.unpaid.rawValue == "未打款")
        #expect(PaymentStatus.paid.rawValue == "已打款")
    }

    @Test func paymentMethodsAreStable() async throws {
        #expect(PaymentMethod.weChat.rawValue == "微信")
        #expect(PaymentMethod.alipay.rawValue == "支付宝")
        #expect(PaymentMethod.bankCard.rawValue == "银行卡")
    }

    @Test func categoryRawValuesAreStable() async throws {
        #expect(AdCategory.clothing.rawValue == "衣服")
        #expect(AdCategory.pants.rawValue == "裤子")
        #expect(AdCategory.skirt.rawValue == "裙子")
        #expect(AdCategory.accessory.rawValue == "配饰")
        #expect(AdCategory.other.rawValue == "其他")
    }

    @Test func workflowRawValuesAreStable() async throws {
        #expect(AdWorkflow.pool.rawValue == "待拍摄")
        #expect(AdWorkflow.scheduled.rawValue == "已排期")
        #expect(AdWorkflow.published.rawValue == "已发布")
        #expect(AdWorkflow.paid.rawValue == "已打款")
    }

    @Test func partnershipRawValuesAreStable() async throws {
        #expect(PartnershipType.consignment.rawValue == "寄拍")
        #expect(PartnershipType.giftedShoot.rawValue == "送拍")
        #expect(PartnershipType.exchange.rawValue == "置换")
    }

    @Test func brandNamesAreCopiedAsNumberedLines() async throws {
        let copyText = numberedBrandNamesCopyText([
            "第一个品牌",
            " 第二个品牌 ",
            "第三个品牌"
        ])

        #expect(copyText == "1️⃣应该是第一个品牌\n2️⃣应该是第二个品牌\n3️⃣应该是第三个品牌")
    }

    @Test func brandNameCopyTextSupportsTenOrMoreItems() async throws {
        let brandNames = (1...11).map { "品牌\($0)" }
        let lines = numberedBrandNamesCopyText(brandNames)
            .components(separatedBy: "\n")

        #expect(lines.count == 11)
        #expect(lines[9] == "🔟应该是品牌10")
        #expect(lines[10] == "1️⃣1️⃣应该是品牌11")
    }

    @Test @MainActor func generatedBrandListImageIsShareable() async throws {
        let image = brandNamesListImage([
            "IIIFORM 南希",
            "NogiUnit 野木小桃",
            "Melindali",
            "rumpumpumpum",
            "RECIT"
        ])

        #expect(image.size.width == 960)
        #expect(image.size.height >= 240)
        #expect(image.pngData()?.isEmpty == false)
    }

    @Test @MainActor func editedTextChangesGeneratedImage() async throws {
        let originalImageData = brandListImage(text: "1️⃣应该是品牌一").pngData()
        let editedImageData = brandListImage(text: "1️⃣应该是修改后的品牌").pngData()

        #expect(originalImageData != nil)
        #expect(editedImageData != nil)
        #expect(originalImageData != editedImageData)
    }
}
