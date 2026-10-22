//
//  QuickTransformServiceTests.swift
//  Tests
//
//  Unit tests for QuickTransformService: JSON formatting & case style conversions.
//

import AppKit
import Foundation

@MainActor
final class QuickTransformServiceTests {
    static func run(runner: TestRunner.Type) {
        print("\n--- Testing QuickTransformService (JSON & Case Conversion) ---")

        testJSONFormatting(runner: runner)
        testInvalidJSONHandling(runner: runner)
        testCaseConversions(runner: runner)
        testWordSplitting(runner: runner)

        print("✓ QuickTransformService tests passed!")
    }

    private static func testJSONFormatting(runner: TestRunner.Type) {
        let compactJSON = "{\"name\":\"Clipboard\",\"version\":1,\"tags\":[\"macOS\",\"swift\"]}"
        let result = QuickTransformService.formatJSON(compactJSON)

        switch result {
        case let .success(formatted):
            runner.assertTrue(formatted.contains("\n"), "Formatted JSON must contain newlines")
            runner.assertTrue(formatted.contains("  \"name\""), "Formatted JSON must have 2-space indentation")
            runner.assertTrue(formatted.contains("  \"tags\""), "Arrays must be indented properly")
        case .failure:
            runner.assertTrue(false, "Valid JSON formatting should not fail")
        }
    }

    private static func testInvalidJSONHandling(runner: TestRunner.Type) {
        let invalidJSON = "{ name: Clipboard, unquoted: true "
        let result = QuickTransformService.formatJSON(invalidJSON)

        switch result {
        case .success:
            runner.assertTrue(false, "Invalid JSON must fail formatting")
        case .failure:
            runner.assertTrue(true, "Invalid JSON is properly reported as error")
        }
    }

    private static func testCaseConversions(runner: TestRunner.Type) {
        let input = "get_user_profile_data"

        runner.assertEqual(
            QuickTransformService.convertCase(input, to: .camel),
            "getUserProfileData",
            "snake_case -> camelCase"
        )
        runner.assertEqual(
            QuickTransformService.convertCase(input, to: .pascal),
            "GetUserProfileData",
            "snake_case -> PascalCase"
        )
        runner.assertEqual(
            QuickTransformService.convertCase(input, to: .kebab),
            "get-user-profile-data",
            "snake_case -> kebab-case"
        )
        runner.assertEqual(
            QuickTransformService.convertCase(input, to: .screamingSnake),
            "GET_USER_PROFILE_DATA",
            "snake_case -> UPPER_CASE"
        )

        // From camelCase
        let camelInput = "sendHttpRequestAsync"
        runner.assertEqual(
            QuickTransformService.convertCase(camelInput, to: .snake),
            "send_http_request_async",
            "camelCase -> snake_case"
        )
        runner.assertEqual(
            QuickTransformService.convertCase(camelInput, to: .kebab),
            "send-http-request-async",
            "camelCase -> kebab-case"
        )
        runner.assertEqual(
            QuickTransformService.convertCase(camelInput, to: .screamingSnake),
            "SEND_HTTP_REQUEST_ASYNC",
            "camelCase -> UPPER_CASE"
        )

        // From kebab-case
        let kebabInput = "custom-auth-header"
        runner.assertEqual(
            QuickTransformService.convertCase(kebabInput, to: .camel),
            "customAuthHeader",
            "kebab-case -> camelCase"
        )
        runner.assertEqual(
            QuickTransformService.convertCase(kebabInput, to: .pascal),
            "CustomAuthHeader",
            "kebab-case -> PascalCase"
        )
    }

    private static func testWordSplitting(runner: TestRunner.Type) {
        let words1 = QuickTransformService.splitWords("APIResponseHelper")
        runner.assertEqual(words1, ["API", "Response", "Helper"], "Handles consecutive uppercase acronyms")

        let words2 = QuickTransformService.splitWords("  kebab-case_with_spaces  and_more ")
        runner.assertEqual(words2, ["kebab", "case", "with", "spaces", "and", "more"], "Handles mixed delimiters")

        let wordsEmpty = QuickTransformService.splitWords("")
        runner.assertEqual(wordsEmpty, [], "Empty text returns empty words")
    }
}
