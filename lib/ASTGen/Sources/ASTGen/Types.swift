//===--- Types.swift ------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ASTBridging
import BasicBridging
import SwiftDiagnostics
@_spi(ExperimentalLanguageFeatures) @_spi(RawSyntax) import SwiftSyntax

extension EffectSpecifiersSyntax {
  var thrownError: TypeSyntax? {
    throwsClause?.type
  }
}

/// Check if an `TypeSyntax` can be generated using ASTGen.
///
/// If all the type nodes that shares the first token are migrated,
/// returns true.
func isTypeMigrated(_ node: TypeSyntax) -> Bool {
  var current: Syntax = Syntax(node)
  if let firstToken = node.firstToken(viewMode: .sourceAccurate) {
    current = firstToken.parent!
  }
  while true {
    switch current.kind {
    // Known implemented kinds.
    case .arrayType, .attributedType, .classRestrictionType, .compositionType,
      .someOrAnyType, .dictionaryType, .functionType, .identifierType,
      .implicitlyUnwrappedOptionalType, .memberType, .metatypeType,
      .namedOpaqueReturnType, .optionalType, .packElementType,
      .packExpansionType, .suppressedType, .tupleType:
      break

    // Known unimplemented kinds.
    case .missingType:
      return false;

    // Unknown type kinds
    case _ where current.is(TypeSyntax.self):
      return false
    default:
      break
    }
    if current.id == node.id {
      return true
    }
    // This is walking up the parents from the first token of `node`. `.parent`
    // must exist if `current` is not `node`
    current = current.parent!
  }
}

extension ASTGenVisitor {
  func generate(type node: TypeSyntax) -> BridgedTypeRepr {
    guard isTypeMigrated(node) else {
      return self.generateWithLegacy(node)
    }
    switch node.as(TypeSyntaxEnum.self) {
    case .arrayType(let node):
      return self.generate(arrayType: node).asTypeRepr
    case .attributedType(let node):
      return self.generate(attributedType: node)
    case .classRestrictionType(let node):
      return self.generate(classRestrictionType: node).asTypeRepr
    case .compositionType(let node):
      return self.generate(compositionType: node).asTypeRepr
    case .dictionaryType(let node):
      return self.generate(dictionaryType: node).asTypeRepr
    case .functionType(let node):
      return self.generate(functionType: node).asTypeRepr
    case .identifierType(let node):
      return self.generate(identifierType: node)
    case .implicitlyUnwrappedOptionalType(let node):
      return self.generate(implicitlyUnwrappedOptionalType: node).asTypeRepr
    case .memberType(let node):
      return self.generate(memberType: node)
    case .metatypeType(let node):
      return self.generate(metatypeType: node)
    case .missingType:
      break
    case .namedOpaqueReturnType(let node):
      return self.generate(namedOpaqueReturnType: node).asTypeRepr
    case .optionalType(let node):
      return self.generate(optionalType: node).asTypeRepr
    case .packElementType(let node):
      return self.generate(packElementType: node).asTypeRepr
    case .packExpansionType(let node):
      return self.generate(packExpansionType: node).asTypeRepr
    case .someOrAnyType(let node):
      return self.generate(someOrAnyType: node)
    case .suppressedType(let node):
      return self.generate(suppressedType: node).asTypeRepr
    case .tupleType(let node):
      return self.generate(tupleType: node).asTypeRepr
    }
    preconditionFailure("isTypeMigrated() mismatch")
  }

  func generate(identifierType node: IdentifierTypeSyntax) -> BridgedTypeRepr {
    let loc = self.generateSourceLoc(node.name)

    // If this is the bare 'Any' keyword, produce an empty composition type.
    if node.name.keywordKind == .Any && node.genericArgumentClause == nil {
      return BridgedCompositionTypeRepr.createEmpty(self.ctx, anyKeywordLoc: loc).asTypeRepr
    }

    let id = self.generateIdentifier(node.name)

    guard let generics = node.genericArgumentClause else {
      return BridgedSimpleIdentTypeRepr.createParsed(ctx, loc: loc, name: id).asTypeRepr
    }

    let genericArguments = generics.arguments.lazy.map {
      self.generate(type: $0.argument)
    }

    return BridgedGenericIdentTypeRepr.createParsed(
      self.ctx,
      name: id,
      nameLoc: loc,
      genericArgs: genericArguments.bridgedArray(in: self),
      leftAngleLoc: self.generateSourceLoc(generics.leftAngle),
      rightAngleLoc: self.generateSourceLoc(generics.rightAngle)
    ).asTypeRepr
  }

  func generate(memberType node: MemberTypeSyntax) -> BridgedTypeRepr {
    // Gather the member components, in decreasing depth order.
    var reverseMemberComponents = [BridgedTypeRepr]()

    var baseType = TypeSyntax(node)
    while let memberType = baseType.as(MemberTypeSyntax.self) {
      let (name, nameLoc) = self.generateIdentifierAndSourceLoc(node.name)

      if let generics = memberType.genericArgumentClause {
        let genericArguments = generics.arguments.lazy.map {
          self.generate(type: $0.argument)
        }

        reverseMemberComponents.append(
          BridgedGenericIdentTypeRepr.createParsed(
            self.ctx,
            name: name,
            nameLoc: nameLoc,
            genericArgs: genericArguments.bridgedArray(in: self),
            leftAngleLoc: self.generateSourceLoc(generics.leftAngle),
            rightAngleLoc: self.generateSourceLoc(generics.rightAngle)
          ).asTypeRepr
        )
      } else {
        reverseMemberComponents.append(
          BridgedSimpleIdentTypeRepr.createParsed(self.ctx, loc: nameLoc, name: name).asTypeRepr
        )
      }

      baseType = memberType.baseType
    }

    let baseComponent = generate(type: baseType)
    let memberComponents = reverseMemberComponents.reversed().bridgedArray(in: self)

    return BridgedMemberTypeRepr.createParsed(
      self.ctx,
      base: baseComponent,
      members: memberComponents
    )
  }

  func generate(arrayType node: ArrayTypeSyntax) -> BridgedArrayTypeRepr {
    let elementType = generate(type: node.element)
    let lSquareLoc = self.generateSourceLoc(node.leftSquare)
    let rSquareLoc = self.generateSourceLoc(node.rightSquare)
    return .createParsed(
      self.ctx,
      base: elementType,
      leftSquareLoc: lSquareLoc,
      rightSquareLoc: rSquareLoc
    )
  }

  func generate(dictionaryType node: DictionaryTypeSyntax) -> BridgedDictionaryTypeRepr {
    let keyType = self.generate(type: node.key)
    let valueType = self.generate(type: node.value)
    let colonLoc = self.generateSourceLoc(node.colon)
    let lSquareLoc = self.generateSourceLoc(node.leftSquare)
    let rSquareLoc = self.generateSourceLoc(node.rightSquare)
    return .createParsed(
      self.ctx,
      leftSquareLoc: lSquareLoc,
      keyType: keyType,
      colonLoc: colonLoc,
      valueType: valueType,
      rightSquareLoc: rSquareLoc
    )
  }

  func generate(metatypeType node: MetatypeTypeSyntax) -> BridgedTypeRepr {
    let baseType = generate(type: node.baseType)
    let tyLoc = self.generateSourceLoc(node.metatypeSpecifier)
    if node.metatypeSpecifier.keywordKind == .Type {
      return BridgedMetatypeTypeRepr.createParsed(
        self.ctx,
        base: baseType,
        typeKeywordLoc: tyLoc
      ).asTypeRepr
    } else {
      assert(node.metatypeSpecifier.keywordKind == .Protocol)
      return BridgedProtocolTypeRepr.createParsed(
        self.ctx,
        base: baseType,
        protocolKeywordLoc: tyLoc
      ).asTypeRepr
    }
  }

  func generate(
    implicitlyUnwrappedOptionalType node: ImplicitlyUnwrappedOptionalTypeSyntax
  ) -> BridgedImplicitlyUnwrappedOptionalTypeRepr {
    let base = generate(type: node.wrappedType)
    let exclaimLoc = self.generateSourceLoc(node.exclamationMark)
    return .createParsed(
      self.ctx,
      base: base,
      exclaimLoc: exclaimLoc
    )
  }

  func generate(optionalType node: OptionalTypeSyntax) -> BridgedOptionalTypeRepr {
    let base = generate(type: node.wrappedType)
    let questionLoc = self.generateSourceLoc(node.questionMark)
    return .createParsed(
      self.ctx,
      base: base,
      questionLoc: questionLoc
    )
  }

  func generate(packElementType node: PackElementTypeSyntax) -> BridgedPackElementTypeRepr {
    let base = generate(type: node.pack)
    let eachLoc = self.generateSourceLoc(node.eachKeyword)
    return .createParsed(
      self.ctx,
      base: base,
      eachKeywordLoc: eachLoc
    )
  }

  func generate(packExpansionType node: PackExpansionTypeSyntax) -> BridgedPackExpansionTypeRepr {
    let base = generate(type: node.repetitionPattern)
    let repeatLoc = self.generateSourceLoc(node.repeatKeyword)
    return .createParsed(
      self.ctx,
      base: base,
      repeatKeywordLoc: repeatLoc
    )
  }

  func generate(tupleType node: TupleTypeSyntax) -> BridgedTupleTypeRepr {
    .createParsed(
      self.ctx,
      elements: self.generate(tupleTypeElementList: node.elements),
      leftParenLoc: self.generateSourceLoc(node.leftParen),
      rightParenLoc: self.generateSourceLoc(node.rightParen)
    )
  }

  func generate(compositionType node: CompositionTypeSyntax) -> BridgedCompositionTypeRepr {
    assert(node.elements.count > 1)

    let types = node.elements.lazy.map {
      generate(type: $0.type)
    }

    return .createParsed(
      self.ctx,
      types: types.bridgedArray(in: self),
      ampersandLoc: self.generateSourceLoc(node.elements.first?.ampersand)
    )
  }

  func generate(functionType node: FunctionTypeSyntax) -> BridgedFunctionTypeRepr {
    .createParsed(
      self.ctx,
      // FIXME: Why does `FunctionTypeSyntax` not have a `TupleTypeSyntax` child?
      argsType: BridgedTupleTypeRepr.createParsed(
        self.ctx,
        elements: self.generate(tupleTypeElementList: node.parameters),
        leftParenLoc: self.generateSourceLoc(node.leftParen),
        rightParenLoc: self.generateSourceLoc(node.rightParen)
      ).asTypeRepr,
      asyncLoc: self.generateSourceLoc(node.effectSpecifiers?.asyncSpecifier),
      throwsLoc: self.generateSourceLoc(node.effectSpecifiers?.throwsSpecifier),
      thrownType: self.generate(type: node.effectSpecifiers?.thrownError),
      arrowLoc: self.generateSourceLoc(node.returnClause.arrow),
      resultType: generate(type: node.returnClause.type)
    )
  }

  func generate(namedOpaqueReturnType node: NamedOpaqueReturnTypeSyntax) -> BridgedNamedOpaqueReturnTypeRepr {
    let baseTy = generate(type: node.type)
    return .createParsed(self.ctx, base: baseTy)
  }

  func generate(someOrAnyType node: SomeOrAnyTypeSyntax) -> BridgedTypeRepr {
    let someOrAnyLoc = self.generateSourceLoc(node.someOrAnySpecifier)
    let baseTy = generate(type: node.constraint)
    if node.someOrAnySpecifier.keywordKind == .some {
      return BridgedOpaqueReturnTypeRepr.createParsed(
        self.ctx,
        someKeywordLoc: someOrAnyLoc,
        base: baseTy
      ).asTypeRepr
    } else {
      assert(node.someOrAnySpecifier.keywordKind == .any)
      return BridgedExistentialTypeRepr.createParsed(
        self.ctx,
        anyKeywordLoc: someOrAnyLoc,
        base: baseTy
      ).asTypeRepr
    }
  }

  func generate(suppressedType node: SuppressedTypeSyntax) -> BridgedInverseTypeRepr {
    return .createParsed(
      self.ctx,
      tildeLoc: self.generateSourceLoc(node.withoutTilde),
      constraint: self.generate(type: node.type)
    )
  }

  func generate(classRestrictionType node: ClassRestrictionTypeSyntax) -> BridgedSimpleIdentTypeRepr {
    // TODO: diagnostics.
    // warning: using 'class' keyword to define a class-constrained protocol is deprecated; use 'AnyObject' instead
    return .createParsed(
      self.ctx,
      loc: self.generateSourceLoc(node.classKeyword),
      name: self.ctx.getIdentifier("AnyObject")
    )
  }

  // NOTE: When implementing new `generate(type:)`, please update  `isTypeMigrated(_:)`.
}

// MARK: - SpecifierTypeRepr/AttributedTypeRepr

extension BridgedAttributedTypeSpecifier {
  fileprivate init?(from keyword: Keyword?) {
    switch keyword {
    case .inout: self = .inOut
    case .borrowing: self = .borrowing
    case .consuming: self = .consuming
    case .__shared: self = .legacyShared
    case .__owned: self = .legacyOwned
    case ._const: self = .const
    case .isolated: self = .isolated
    case ._resultDependsOn: self = .resultDependsOn
    default: return nil
    }
  }
}

extension ASTGenVisitor {
  func generate(attributedType node: AttributedTypeSyntax) -> BridgedTypeRepr {
    var type = generate(type: node.baseType)

    // Handle specifiers.
    if let specifier = node.specifier {
      if let kind = BridgedAttributedTypeSpecifier(from: specifier.keywordKind) {
        type =
          BridgedSpecifierTypeRepr.createParsed(
            self.ctx,
            base: type,
            specifier: kind,
            specifierLoc: self.generateSourceLoc(specifier)
          ).asTypeRepr
      } else {
        self.diagnose(Diagnostic(node: specifier, message: UnexpectedTokenKindError(token: specifier)))
      }
    }

    // Handle type attributes.
    if !node.attributes.isEmpty {
      let typeAttributes = BridgedTypeAttributes(context: self.ctx)
      for attributeElt in node.attributes {
        // FIXME: Ignoring #ifs entirely. We want to provide a filtered view,
        // but we don't have that ability right now.
        guard case let .attribute(attribute) = attributeElt else {
          continue
        }

        // Only handle simple attribute names right now.
        guard let identType = attribute.attributeName.as(IdentifierTypeSyntax.self) else {
          continue
        }

        let nameSyntax = identType.name
        let typeAttrKind = BridgedTypeAttrKind(from: nameSyntax.rawText.bridged)
        let atLoc = self.generateSourceLoc(attribute.atSign)
        let attrLoc = self.generateSourceLoc(nameSyntax)
        switch typeAttrKind {
        // SIL attributes
        // FIXME: Diagnose if not in SIL mode? Or should that move to the
        // type checker?
        case .out, .in, .owned, .unowned_inner_pointer, .guaranteed,
          .autoreleased, .callee_owned, .callee_guaranteed, .objc_metatype,
          .sil_weak, .sil_unowned, .inout, .block_storage, .box,
          .dynamic_self, .sil_unmanaged, .error, .error_indirect,
          .error_unowned, .direct, .inout_aliasable,
          .in_guaranteed, .in_constant, .captures_generics, .moveOnly,
          .isolated:
          fallthrough

        case .autoclosure, .escaping, .noescape, .noDerivative, .async,
          .sendable, .retroactive, .unchecked, .preconcurrency, ._local,
          ._noMetadata, .pack_owned, .pack_guaranteed, .pack_inout, .pack_out,
          .pseudogeneric, .yields, .yield_once, .yield_many, .thin, .thick,
          .count, .unimplementable:
          typeAttributes.addSimpleAttr(kind: typeAttrKind, atLoc: atLoc, attrLoc: attrLoc)

        case .opened, .pack_element, .differentiable, .convention,
          ._opaqueReturnTypeOf:
          // FIXME: These require more complicated checks
          break
        }
      }

      if (!typeAttributes.isEmpty) {
        type =
          BridgedAttributedTypeRepr.createParsed(
            base: type,
            consumingAttributes: typeAttributes
          ).asTypeRepr
      }
    }

    return type
  }
}

extension ASTGenVisitor {
  func generate(tupleTypeElementList node: TupleTypeElementListSyntax) -> BridgedArrayRef {
    node.lazy.map { element in
      let (firstName, firstNameLoc) =
        self.generateIdentifierAndSourceLoc(element.firstName)
      let (secondName, secondNameLoc) = self.generateIdentifierAndSourceLoc(element.secondName)
      var type = generate(type: element.type)
      if let ellipsis = element.ellipsis {
        type =
          BridgedVarargTypeRepr.createParsed(
            self.ctx,
            base: type,
            ellipsisLoc: self.generateSourceLoc(ellipsis)
          ).asTypeRepr
      }

      return BridgedTupleTypeElement(
        Name: firstName,
        NameLoc: firstNameLoc,
        SecondName: secondName,
        SecondNameLoc: secondNameLoc,
        UnderscoreLoc: nil, /*N.B. Only important for SIL*/
        ColonLoc: self.generateSourceLoc(element.colon),
        Type: type,
        TrailingCommaLoc: self.generateSourceLoc(element.trailingComma)
      )
    }.bridgedArray(in: self)
  }
}
