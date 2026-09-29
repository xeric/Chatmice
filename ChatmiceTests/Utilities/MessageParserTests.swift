//
//  MessageParser.swift
//  ChatmiceTests
//
//  Created by Renat Notfullin on 25.04.2023.
//

import XCTest

@testable import Chatmice

class MessageParserTests: XCTestCase {

    var parser: MessageParser!

    override func setUp() {
        super.setUp()
        parser = MessageParser(colorScheme: .light)
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    /*
     Test generic message with table
     */
    func testParseMessageFromStringGeneric() {
        let input = """
            This is a sample text.

            Table: Test Table
            | Column 1 | Column 2 |
            | -------- | -------- |
            | Value 1  | Value 2  |
            | Value 3  | Value 4  |

            This is another sample text.
            """

        let result = parser.parseMessageFromString(input: input)
        XCTAssertEqual(result.count, 3)

        switch result[0] {
        case .text(let text):
            XCTAssertEqual(
                text,
                """
                This is a sample text.

                Table: Test Table
                """
            )
        default:
            XCTFail("Expected .text element")
        }

        switch result[1] {
        case .table(let header, let data):
            XCTAssertEqual(header, ["Column 1", "Column 2"])
            XCTAssertEqual(data, [["Value 1", "Value 2"], ["Value 3", "Value 4"]])
        default:
            XCTFail("Expected .table element")
        }

        switch result[2] {
        case .text(let text):
            XCTAssertEqual(text, "This is another sample text.")
        default:
            XCTFail("Expected .text element")
        }
    }

    /*
     Test incomplete message in response
     https://github.com/Renset/macai/issues/15
     */
    func testParseMessageFromStringGitHubIssue15() {
        let input = """
            Here's a FizzBuzz implementation in Shakespeare Programming Language:

            ```
            The Infamous FizzBuzz Program.
            By ChatGPT.

            Act 1: The Setup
            Scene 1: Initializing Variables.
            [Enter Romeo and Juliet]
            """

        let result = parser.parseMessageFromString(input: input)
        XCTAssertEqual(result.count, 2)

        switch result[0] {
        case .text(let text):
            XCTAssertEqual(text, "Here's a FizzBuzz implementation in Shakespeare Programming Language:\n")
        default:
            XCTFail("Expected .text element")
        }

        switch result[1] {
        case .code(code: let highlightedCode):
            XCTAssertEqual(
                String(highlightedCode.code),
                """
                The Infamous FizzBuzz Program.
                By ChatGPT.

                Act 1: The Setup
                Scene 1: Initializing Variables.
                [Enter Romeo and Juliet]
                """
            )
        default:
            XCTFail("Expected .code element")
        }
    }

    /*
     Test message with the mix of tables and code blocks
     */
    func testParseMessageFromStringTableAndCode() {
        let input = """
            Table: Test Table
            | Column 1 | Column 2 |
            | -------- | -------- |
            | Value 1  | Value 2  |
            | Value 3  | Value 4  |

            ```
            This is a code block
            ```

            **Table 2: Test Table
            | Column 1 | Column 2 |
            | -------- | -------- |
            | Value 1  | Value 2  |
            | Value 3  | Value 4  |

            **Table 3: Test Table
            | Column 1 | Column 2 |
            | -------- | -------- |
            | Value 1  | Value 2  |
            | Value 3  | Value 4  |

            Some random text. Bla-bla-bla...

            **Table 4: Test Table
            | Column 1 | Column 2 |
            | -------- | -------- |
            | Value 1  | Value 2  |
            | Value 3  | Value 4  |

            """

        let result = parser.parseMessageFromString(input: input)
        XCTAssertEqual(result.count, 11)

        switch result[1] {
        case .table(let header, let data):
            XCTAssertEqual(header, ["Column 1", "Column 2"])
            XCTAssertEqual(data, [["Value 1", "Value 2"], ["Value 3", "Value 4"]])
        default:
            XCTFail("Expected .table element")
        }

        switch result[3] {
        case .code(code: let highlightedCode):
            XCTAssertEqual(
                String(highlightedCode.code),
                """
                This is a code block
                """
            )
        default:
            XCTFail("Expected .code element")
        }

        switch result[5] {
        case .table(let header, let data):
            XCTAssertEqual(header, ["Column 1", "Column 2"])
            XCTAssertEqual(data, [["Value 1", "Value 2"], ["Value 3", "Value 4"]])
        default:
            XCTFail("Expected .table element")
        }

        switch result[7] {
        case .table(let header, let data):
            XCTAssertEqual(header, ["Column 1", "Column 2"])
            XCTAssertEqual(data, [["Value 1", "Value 2"], ["Value 3", "Value 4"]])
        default:
            XCTFail("Expected .table element")
        }

        switch result[8] {
        case .text(let text):
            XCTAssertEqual(
                text,
                """
                Some random text. Bla-bla-bla...

                **Table 4: Test Table
                """
            )
        default:
            XCTFail("Expected .text element")
        }

        switch result[9] {
        case .table(let header, let data):
            XCTAssertEqual(header, ["Column 1", "Column 2"])
            XCTAssertEqual(data, [["Value 1", "Value 2"], ["Value 3", "Value 4"]])
        default:
            XCTFail("Expected .table element")
        }
    }

    func testParseMessageFromStringMathEquation() {
        let input = """
            Sure, here’s a complex formula from the field of string theory, specifically the action for the bosonic string:

            \\[
            S = -\\frac{1}{4\\pi\\alpha'} \\int d\\tau \\, d\\sigma \\, \\sqrt{-h} \\left( h^{ab} \\partial_a X^\\mu \\partial_b X_\\mu + \\alpha' R^{(2)} \\Phi(X) \\right)
            \\]

            Where:
            - \\( S \\) is the action.
            - \\( \\alpha' \\) is the string tension parameter.
            - \\( \\tau \\) and \\( \\sigma \\) are the worldsheet coordinates.
            - \\( h \\) is the determinant of the worldsheet metric \\( h_{ab} \\).
            - \\( h^{ab} \\) is the inverse of the worldsheet metric.
            - \\( \\partial_a \\) denotes partial differentiation with respect to the worldsheet coordinates.
            - \\( X^\\mu \\) are the target space coordinates of the string.
            - \\( R^{(2)} \\) is the Ricci scalar of the worldsheet.
            - \\( \\Phi(X) \\) is the dilaton field.
            """

        let result = parser.parseMessageFromString(input: input)
        XCTAssertEqual(result.count, 3)

        switch result[0] {
        case .text(let text):
            XCTAssertEqual(
                text,
                """
                Sure, here’s a complex formula from the field of string theory, specifically the action for the bosonic string:

                """
            )
        default:
            XCTFail("Expected .text element")
        }

        switch result[1] {
        case .formula(let formula):
            XCTAssertEqual(
                formula,
                "S = -\\frac{1}{4\\pi\\alpha'} \\int d\\tau \\, d\\sigma \\, \\sqrt{-h} \\left( h^{ab} \\partial_a X^\\mu \\partial_b X_\\mu + \\alpha' R^{(2)} \\Phi(X) \\right)"
            )
        default:
            XCTFail("Expected .formula element")
        }

        switch result[2] {
        case .text(let text):
            XCTAssertEqual(
                text,
                """
                Where:
                - \\( S \\) is the action.
                - \\( \\alpha' \\) is the string tension parameter.
                - \\( \\tau \\) and \\( \\sigma \\) are the worldsheet coordinates.
                - \\( h \\) is the determinant of the worldsheet metric \\( h_{ab} \\).
                - \\( h^{ab} \\) is the inverse of the worldsheet metric.
                - \\( \\partial_a \\) denotes partial differentiation with respect to the worldsheet coordinates.
                - \\( X^\\mu \\) are the target space coordinates of the string.
                - \\( R^{(2)} \\) is the Ricci scalar of the worldsheet.
                - \\( \\Phi(X) \\) is the dilaton field.
                """
            )
        default:
            XCTFail("Expected .text element")
        }

    }
    func testParseToolActivityBetweenTextBlocks() {
        let activity = ToolActivityRecord(
            name: "bash",
            input: "ls -la /",
            output: "Applications\nLibrary\n[exit code: 0]",
            isError: false
        )
        let input = "Before\n\(activity.marker)\nAfter"

        let result = parser.parseMessageFromString(input: input)

        XCTAssertEqual(result.count, 3)
        guard case .toolActivity(let parsed) = result[1] else {
            return XCTFail("Expected .toolActivity element")
        }
        XCTAssertEqual(parsed, activity)

        let modelContent = ToolActivityRecord.replacingMarkersForModel(in: input)
        XCTAssertFalse(modelContent.contains(ToolActivityRecord.openingTag))
        XCTAssertTrue(modelContent.contains("Tool bash completed"))
        XCTAssertTrue(modelContent.contains("Applications"))
    }

    func testInlineMathParserRecognizesBackslashAndDollarDelimiters() {
        let segments = InlineMathParser.parse("Energy \\(E = mc^2\\) and $x^2 + y^2$.")

        XCTAssertEqual(
            segments,
            [
                .text("Energy "),
                .formula(latex: "E = mc^2", source: "\\(E = mc^2\\)"),
                .text(" and "),
                .formula(latex: "x^2 + y^2", source: "$x^2 + y^2$"),
                .text("."),
            ]
        )
    }

    func testInlineMathParserIgnoresCodeAndCurrency() {
        let input = "Use `\\(raw\\)` and `$value$`; prices are $10 and $20."

        XCTAssertEqual(InlineMathParser.parse(input), [.text(input)])
    }

    func testInlineMathParserLeavesIncompleteFormulaAsText() {
        let input = "Streaming \\(x + y"

        XCTAssertEqual(InlineMathParser.parse(input), [.text(input)])
    }

}
