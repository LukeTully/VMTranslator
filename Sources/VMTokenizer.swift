//
//  VMTokenizer.swift
//  HackVMTranslator
//
//  Created by Luke Tully on 2024-04-08
//
//  The tokenization process is composed of methods that piece together arrays of strings
//  that form instruction sets in Hack Assembly. This pattern is not the only or most performant way to accomplish this task,
//  but it seemed like the best way to accomplish the task and be somewhat readable.

import Foundation

enum ArithmeticCommand: String {
    case add = "+"
    case sub = "-"
    case and = "&"
    case or = "|"
}

let arithmeticCommandMap: [String: ArithmeticCommand] = [
    "add": .add,
    "sub": .sub,
    "and": .and,
    "or": .or,
]

struct FunctionDefinition: Hashable {
    var labelName: String
    var nLocalVars: Int
}

struct CallSignature: Hashable {
    var labelName: String
    var nArgs: Int
}

enum Comparator: String {
    case eq = "D;JEQ"
    case gt = "D;JGT"
    case lt = "D;JLT"
}

let comparatorCommandMap: [String: Comparator] = [
    "eq": .eq,
    "gt": .gt,
    "lt": .lt,
]
struct ComparisonJumpCommand {
    var positiveJumpCondition: String
    var negativeJumpCondition: String
}

let comparisonMap: [Comparator: ComparisonJumpCommand] = [
    .eq: ComparisonJumpCommand(positiveJumpCondition: "D;JEQ", negativeJumpCondition: "D;JNE"),
    .lt: ComparisonJumpCommand(positiveJumpCondition: "D;JLT", negativeJumpCondition: "D;JGE"),
    .gt: ComparisonJumpCommand(positiveJumpCondition: "D;JGT", negativeJumpCondition: "D;JLE"),
]

enum UnaryCommand: String {
    case neg = "-"
    case not = "!"
}

let unaryCommandMap: [String: UnaryCommand] = [
    "neg": .neg,
    "not": .not,
]

enum ControlFlowCommand: String {
    case ifGoto = "if-goto"
    case goto = "goto"
    case functionDef = "function"
    case callFunction = "call"
    case functionReturn = "return"
    case putLabel = "label"
}

enum StackCommand: String {
    case pop
    case push
}

enum DestinationSegment {
    case LCL
    case THIS
    case THAT
    case CONST
    case STATIC
    case ARGUMENT
    case POINTER
    case TEMP
}

// DTO - Package describing the properties of a legal instruction
struct VMInstruction: Hashable {
    let binaryOperator: ArithmeticCommand?
    let comparator: Comparator?
    let unaryOperator: UnaryCommand?
    let stackCommand: StackCommand?
    let dest: DestinationSegment?
    let index: Int?
    let originalCommand: String?
    let controlFlowCommand: ControlFlowCommand?
    let conditionalJumpLabel: String?
    let unconditionalJumpLabel: String?
    let callFunction: CallSignature?
    let isReturnStatement: Bool?
    let putLabelValue: String?
    let functionDef: FunctionDefinition?
}

class VMTokenizer {
    var comparisonLabelIndex = 0

    /* Stack Operation Labels */
    private var arithmeticLabels: Set<ArithmeticCommand> = Set()
    private var comparisonLabels: Set<Comparator> = Set()

    /* Custom Labels / Functions */
    private let STACK_PUSH_LABEL = "STACK_PUSH"
    private let WRITE_BOOL_LABEL = "WRITE_BOOL"
    private let WRITE_TRUE_LABEL = "WRITE_TRUE"

    /* State */
    private var stackPushLabelGenerated = false
    private var hasWrittenBoolLabel = false
    private var staticPrefix: String
    private var functionReturnIndex: [String: Int] = [:]

    /* Constants */
    private let STORED_FRAME_LABELS = [
        "LCL",
        "ARG",
        "THIS",
        "THAT",
    ]

    init(staticPrefix: String) {
        self.staticPrefix = staticPrefix
    }

    func setStaticPrefix(prefix: String) {
        staticPrefix = prefix
    }

    func bootstrapVMTranslator(
        callInit: Bool = false,
        stackPointerBase: String
    ) -> [String] {
        var callInstructions = writeCall(calleeName: "Sys.init", calleeArgs: 0)
        var segmentPointerLabelInitializers = [
            "@SP",
            "@LCL",
            "@ARG",
            "@THIS",
            "@THAT",
            "@R5",
            "@R6",
            "@R7",
            "@R8",
            "@R9",
            "@R10",
            "@R11",
            "@R12",
            "@R13",
            "@R14",
            "@R15",
        ]

        let segmentBasePointers: [(String, String)] = [
            ("SP", stackPointerBase), // Change this if testing NestedCalls or lower
            ("LCL", stackPointerBase),
            ("ARG", stackPointerBase),
            ("THIS", "3000"),
            ("THAT", "4000"),
        ]

        return [
            segmentPointerLabelInitializers,
            segmentBasePointers.reduce(into: []) {
                $0.append(contentsOf:
                    [
                        "@\($1.1)",
                        "D=A",
                        "@\($1.0)",
                        "M=D",
                    ]
                )
            },
            callInit ? callInstructions : [],
        ].flatMap { $0 }
    }

    private func writeCall(
        calleeName: String,
        calleeArgs: Int
    ) -> [String] {
        let returnIndex = (functionReturnIndex[calleeName] ?? 0) + 1
        let returnSymbol = "\(calleeName)$ret.\(returnIndex)"
        
        functionReturnIndex.updateValue(
            returnIndex,
            forKey: calleeName
        )
        
        let swapArgReverseInstructions = [
            "@\(5 + calleeArgs)",
            "D=A",
            "@SP",
            "D=M-D",
            "D=D-A",
            "@ARG // Reposition ARG in preparation for calling the function",
            "M=D",
        ]
        
        let storeFrameInstructions = storeFrame(nArgs: calleeArgs)
        let storeReturnAddrInstructions = [
            "@\(returnSymbol)",
            "D=A",
            "@SP",
            "A=M",
            "M=D",
            "@SP",
            "M=M+1",
        ]
        let jumpToReturnAddrInstruction = [
            "@\(calleeName)",
            "0;JMP",
            "(\(returnSymbol))",
        ]
        
        return [
            storeFrameInstructions,
            swapArgReverseInstructions,
            jumpToReturnAddrInstruction
        ].flatMap {$0}
    }

    private func storeFrame(nArgs: Int) -> [String] {
        var result: [String] = STORED_FRAME_LABELS.flatMap {
            [
                "@\($0) // Storing frame part \($0)", // Start storing frame - select the segment pointer (LCL, ARG, THIS, THAT)
                "D=M", // Store the selected pointer in D
                "@SP", // Select the stack pointer
                "A=M", // Navigate to the stack pointer's address
                "M=D", // Push the selected segment pointer onto the stack
                "@SP",  // Reselect the stack pointer
                "MD=M+1 // End Storing Frame part \($0)", // Increment the stack pointer
            ]
        }

        return result
    }

    private func writeFunctionDef(
        symbolName: String,
        locals: Int
    ) -> [String] {
        var result = [
            "(\(symbolName)) // Start functionDef for \(symbolName)",
            "@SP",
            "D=M",
            "@LCL", // Init LCL by copying SP
            "M=D",
        ]

        if locals > 0 {
            for i in 0 ... locals - 1 {
                result.append(
                    contentsOf: [
                        "@\(i) // Initialize local \(i) for functionDef \(symbolName)",
                        "D=A",
                        "@LCL",
                        "A=M+D",
                        "M=0 // Completes local \(i) for functionDef \(symbolName)",
                    ]
                )
            }
        }

        result.append(
            contentsOf: [
                "@\(locals)",
                "D=A",
                "@LCL",
                "D=M+D", // Should be one past the last local initialized or @LCL
                "@SP",
                "M=D // End functionDef initialization for \(symbolName)",
            ]
        )
        return result
    }

    private func restoreFrame() -> [String] {
        /* Happens during the return process, and is part of the final stage of a function's executution */
        var result: [String] = [
            "@5 // Start the frame restoration process",
            "D=A",
            "@LCL",
            "AD=M-D", // Return Addr should be stored immediately before the frame pointers at LCL - 5
            "D=M",
            "@R13",
            "M=D",
            "@ARG", // Store the current arg 0 address, because this will become the basis for the new @SP after frame restoration
            "D=M",
            "@R15",
            "M=D",
            "@SP",
            "A=M-1",
            "D=M",
            "@ARG",
            "A=M",
            "M=D",
            "@LCL",
            "D=M", // The last pointer in the frame will be stored 1 prior in the global stack to the LCL pointer of the callee
            "@R14", // Select a general purpose register that will act as a temporary location for the LCL location in RAM
            "M=D", // Store the location of the LCL segment
        ]

        /* Unwind the caller's stack frame */
        result.append(
            contentsOf: STORED_FRAME_LABELS.reversed().flatMap {
                [
                    "@R14",
                    "AM=M-1", // Start decrementing from the last LCL that was stored in R14
                    "D=M", // Retrieve the frame element at this position
                    "@\($0)",
                    "M=D",
                ]
            }
        )

        result.append(
            contentsOf: [
                "@R15", // Previous top of the stack was stored in R15
                "D=M",
                "@SP", // Restore the stack pointer and increment, Any future stack operations expect @SP to be one past the last value on the stack
                "M=D+1",
                "@R13",
                "A=M",
                "0;JMP // End frame restoration process", // Jump to the return address previously stored in R13
            ]
        )

        return result
    }

    private func writeConditionalGoto(symbolName: String) -> [String] {
        return [
            "@SP // Start Condition GOTO for \(symbolName)", // Pop the top off the stack
            "AM=M-1",
            "D=M",
            "@\(symbolName)",
            "D;JNE",
        ]
    }

    private func writeGoto(symbolName: String) -> [String] {
        return [
            "@\(symbolName)",
            "0;JMP",
        ]
    }

    private func performPop(from vmInstruction: VMInstruction) -> [String] {
        var result: [String] = []

        // Pop off the stack
        result.append(contentsOf: convertPop(from: vmInstruction))

        // Store the stack value in a register
        result.append(
            contentsOf: [
                "@R14",
                "M=D",
            ]
        )

        if let d = vmInstruction.dest,
           let index = vmInstruction.index
        {
            // Calculate the destination index
            var segmentOffsetInstructions = selectSegmentIndex(
                dest: d,
                index: index
            )

            // Store the calculated dest in another register
            segmentOffsetInstructions.append(
                contentsOf: [
                    "D=A",
                    "@R13",
                    "M=D",
                    "@R14", // Re-read the previous stack value
                    "D=M",
                    "@R13",
                    "A=M",
                    "M=D", // Store the previous stack value in the final destination
                ]
            )
            result.append(contentsOf: segmentOffsetInstructions)
        }

        return result
    }

    private func performPush(from vmInstruction: VMInstruction) -> [String] {
        var result: [[String]] = []

        if let d = vmInstruction.dest,
           let index = vmInstruction.index
        {
            result.append(
                contentsOf:
                [
                    readFromSegment(
                        dest: d,
                        segmentIndex: index
                    ),
                    convertPush(from: vmInstruction),
                ]
            )
        }

        return result.flatMap { $0 }
    }

    private func performStackOperation(vmInstruction: VMInstruction) -> [String] {
        if let binOp = vmInstruction.binaryOperator {
            return convertBinaryArithmetic(symbol: binOp)
        }

        if let comparison = vmInstruction.comparator {
            return generateComparison(expression: comparisonMap[comparison]!)
        }

        if let unaryOperator = vmInstruction.unaryOperator {
            return convertUnaryArithmetic(symbol: unaryOperator)
        }

        return []
    }

    private func convertPop(from vmInstruction: VMInstruction) -> [String] {
        var result: [String] = []
        result.append("@SP")
        result.append("AM=M-1")
        result.append("D=M")

        return result
    }

    private func convertPush(from vmInstruction: VMInstruction) -> [String] {
        return [
            "@SP",
            "A=M",
            "M=D", // D should be already set to a value
            "@SP",
            "M=M+1",
        ]
    }

    private func convertBinaryArithmetic(symbol: ArithmeticCommand) -> [String] {
        return [
            "@SP", // Pop off the stack
            "AM=M-1",
            "D=M",
            "@R15", // Store the value in R15
            "M=D",
            "@SP", // Pop another
            "AM=M-1",
            "D=M",
            "@R15",
            "D=D\(symbol.rawValue)M",
            "@SP",
            "A=M", // Navigate back to stack top
            "M=D", // Store the binary arithmetic result
            "@SP",
            "M=M+1", // Increment stack pointer once more
        ]
    }

    private func convertUnaryArithmetic(symbol: UnaryCommand) -> [String] {
        return [
            "@SP", // Decrement stack by 1
            "AM=M-1",
            "M=\(symbol.rawValue)M", // Replace top of stack with unaried value
            "@SP", // Re-increment stack pointer
            "M=M+1",
        ]
    }

    private func getSegmentString(
        dest: DestinationSegment,
        constIndex: Int
    ) -> String {
        let THIS_LABEL = "@THIS"
        let THAT_LABEL = "@THAT"

        switch dest {
            case .LCL:
                return "@LCL"
            case .THIS:
                return THIS_LABEL
            case .THAT:
                return THAT_LABEL
            case .ARGUMENT:
                return "@ARG"
            case .POINTER:
                if constIndex == 1 {
                    return THAT_LABEL
                }
                return THIS_LABEL // TODO: This should be one of many conditions that are checked earlier for validity
            case .TEMP:
                return "@\(5 + constIndex)"
            case .CONST:
                return "@\(constIndex)"
            case .STATIC:
                return "@\(staticPrefix).\(constIndex)"
        }
    }

    private func readFromSegment(
        dest: DestinationSegment,
        segmentIndex: Int
    ) -> [String] {
        // The last instruction here should have set the D register to the value stored at the segment base + index
        var results: [String] = selectSegmentIndex(dest: dest, index: segmentIndex)
        if dest != .CONST {
            results.append("D=M")
        }
        return results
    }

    private func selectSegmentIndex(
        dest: DestinationSegment,
        index: Int
    ) -> [String] {
        var results: [String] = [
            getSegmentString(dest: dest, constIndex: index),
        ]
        if dest == .TEMP ||
            dest == .POINTER ||
            dest == .STATIC
        {
            return results
        }

        if dest != .CONST {
            results.append(
                contentsOf: [
                    "D=M",
                    "@\(index)",
                    "A=D+A",
                ]
            )
        } else {
            results.append("AD=A")
        }
        return results
    }

    private func writeToSegment(dest: DestinationSegment, index: Int) -> [String] {
        var segmentInstructions = selectSegmentIndex(dest: dest, index: index)
        segmentInstructions.append("D=M")
        return segmentInstructions
    }

    private func writeToStack() -> [String] {
        /* Writes the value stored in the D register to the stack */
        if stackPushLabelGenerated {
            return [
                "@\(STACK_PUSH_LABEL)",
                "0;JMP",
            ]
        } else {
            stackPushLabelGenerated = true
            return [
                "(\(STACK_PUSH_LABEL))",
                "@SP",
                "AM=M+1",
                "M=D",
            ]
        }
    }

    private func generateArithmeticFunction(expression: ArithmeticCommand) -> [String] {
        let labelName = "\(expression.rawValue)"
        if arithmeticLabels.contains(expression) {
            return [
                "@\(labelName)",
                "0;JMP",
            ]
        } else {
            return [
                "(\(labelName)",
                "D=M\(expression.rawValue)D",
            ]
        }
    }

    private func writeBool(jump: Comparator) -> [String] {
        var result: [String] = []
        if hasWrittenBoolLabel {
            // Jump to the writeBool label if it already exists
            result.append(
                contentsOf: [
                    "@\(WRITE_BOOL_LABEL)",
                    "0;JMP",
                ]
            )
        } else {
            result.append(
                contentsOf: [
                    "(\(WRITE_BOOL_LABEL))",
                    "@R15",
                    "@\(WRITE_TRUE_LABEL)",
                ]
            )
        }

        // Handle jump
        result.append(jump.rawValue)
        return result.compactMap { $0 }
    }

    private func generateComparison(expression: ComparisonJumpCommand) -> [String] {
        var results: [String] = [
            [
                "@SP", // Pop off the stack
                "AM=M-1",
                "D=M",
                "@R15",
                "M=D",
                "@SP",
                "AM=M-1",
                "D=M",
                "@R15",
                "D=D-M", // Compares lower stack item to higher stack item
                "@PUSH_TRUE_\(comparisonLabelIndex)",
                expression.positiveJumpCondition,
                "@PUSH_FALSE_\(comparisonLabelIndex)",
                expression.negativeJumpCondition,
                "(PUSH_TRUE_\(comparisonLabelIndex))",
                "@SP",
                "A=M",
                "M=-1",
                "@SP",
                "M=M+1",
                "@JUMP_BACK_\(comparisonLabelIndex)",
                "0;JEQ",
                "(PUSH_FALSE_\(comparisonLabelIndex))",
                "@SP",
                "A=M",
                "M=0",
                "@SP",
                "M=M+1",
                "(JUMP_BACK_\(comparisonLabelIndex))",
            ],
        ].flatMap { $0 }

        comparisonLabelIndex += 1
        return results
    }

    func translate(from vmInstruction: VMInstruction) -> [String] {
        var translatedInstructionList: [String] = []

        if let pushOrPop = vmInstruction.stackCommand {
            switch pushOrPop {
                case .pop:
                    translatedInstructionList.append(contentsOf: performPop(from: vmInstruction))
                case .push:
                    translatedInstructionList.append(contentsOf: performPush(from: vmInstruction))
            }
        } else if let controlFlowCommand = vmInstruction.controlFlowCommand {
            switch controlFlowCommand {
                case .callFunction:
                    if let validCallSig = vmInstruction.callFunction {
                        translatedInstructionList.append(
                            contentsOf: writeCall(
                                calleeName: validCallSig.labelName,
                                calleeArgs: Int(validCallSig.nArgs)
                            )
                        )
                    }
                case .functionDef:
                    if let validFuncDef = vmInstruction.functionDef {
                        translatedInstructionList.append(
                            contentsOf: writeFunctionDef(
                                symbolName: validFuncDef.labelName,
                                locals: validFuncDef.nLocalVars
                            )
                        )
                    }
                case .functionReturn:
                    if let isReturnStatement = vmInstruction.isReturnStatement {
                        translatedInstructionList.append(contentsOf: restoreFrame())
                    }
                case .goto:
                    if let gotoStatement = vmInstruction.unconditionalJumpLabel {
                        translatedInstructionList.append(contentsOf: writeGoto(symbolName: gotoStatement))
                    }
                case .ifGoto:
                    if let conditionalJumpLabel = vmInstruction.conditionalJumpLabel {
                        translatedInstructionList.append(contentsOf: writeConditionalGoto(symbolName: conditionalJumpLabel))
                    }
                case .putLabel:
                    if let putLabelValue = vmInstruction.putLabelValue {
                        translatedInstructionList.append(
                            "(\(putLabelValue))"
                        )
                    }
            }
        } else {
            translatedInstructionList.append(contentsOf: performStackOperation(vmInstruction: vmInstruction))
        }

        // Append a comment that denotes the original VM command
        if translatedInstructionList.indices.contains(0) {
            if let og = vmInstruction.originalCommand {
                translatedInstructionList[0].append(" // \(og)")
            }
        }

        return translatedInstructionList
    }

    func finish(remainingInstructions: [String]? = []) -> [String] {
        /* Once each line has been translated, write any symbols or loops that need to end the program */
        var result: [String] = remainingInstructions ?? []

        result.append(contentsOf: [
            "@END",
            "0;JMP",
            "(END)",
            "@END",
            "0;JMP",
            "(\(WRITE_TRUE_LABEL))",
            "D=1",
        ])
        result.append(contentsOf: writeToStack())
        return result.compactMap { $0 }
    }
}
