//
//  GenericType.swift
//  MockingbirdCli
//
//  Created by Andrew Chang on 8/10/19.
//  Copyright © 2019 Bird Rides, Inc. All rights reserved.
//

import Foundation
import SourceKittenFramework

struct WhereClause: Equatable, Hashable, CustomStringConvertible {
  enum Operator: String {
    case conforms = ":"
    case equals = "=="
  }
  
  var description: String {
    switch `operator` {
    case .conforms: return "\(constrainedTypeName)\(self.operator.rawValue) \(genericConstraint)"
    case .equals: return "\(constrainedTypeName) \(self.operator.rawValue) \(genericConstraint)"
    }
  }
  
  let constrainedTypeName: String
  let genericConstraint: String
  let `operator`: Operator
  
  init?(from declaration: String) {
    if let conformsIndex = declaration.firstIndex(of: Operator.conforms.rawValue.first!) {
      self.operator = .conforms
      self.constrainedTypeName = declaration[..<conformsIndex]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      self.genericConstraint = declaration[declaration.index(after: conformsIndex)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } else if let equalsRange = declaration.range(of: Operator.equals.rawValue) {
      self.operator = .equals
      self.constrainedTypeName = declaration[..<equalsRange.lowerBound]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      self.genericConstraint = declaration[equalsRange.upperBound...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      return nil
    }
  }
  
  init(constrainedTypeName: String, genericConstraint: String, operator: Operator) {
    self.constrainedTypeName = constrainedTypeName
    self.genericConstraint = genericConstraint
    self.operator = `operator`
  }
}

struct GenericType: Hashable {
  let name: String
  let constraints: Set<String> // A set of type names
  let whereClauses: [WhereClause]
  
  struct Reduced: Hashable {
    let name: String
    init(from genericType: GenericType) {
      self.name = genericType.name
    }
  }
  
  init?(from dictionary: StructureDictionary,
        rawType: RawType,
        moduleNames: [String],
        rawTypeRepository: RawTypeRepository) {
    guard let kind = SwiftDeclarationKind(from: dictionary),
      kind == .genericTypeParam || kind == .associatedtype,
      let name = dictionary[SwiftDocKey.name.rawValue] as? String
      else { return nil }
    
    self.name = name
    
    var constraints: Set<String>
    if let rawInheritedTypes = dictionary[SwiftDocKey.inheritedtypes.rawValue] as? [StructureDictionary] {
      constraints = GenericType.parseInheritedTypes(rawInheritedTypes: rawInheritedTypes,
                                                    moduleNames: moduleNames,
                                                    rawType: rawType,
                                                    rawTypeRepository: rawTypeRepository)
    } else {
      constraints = []
    }
    
    let whereClauses: [WhereClause]
    if kind == .associatedtype {
      whereClauses = GenericType.parseAssociatedTypes(constraints: &constraints,
                                                      rawType: rawType,
                                                      dictionary: dictionary,
                                                      moduleNames: moduleNames,
                                                      rawTypeRepository: rawTypeRepository)
    } else {
      whereClauses = []
    }
    self.whereClauses = whereClauses
    self.constraints = constraints
  }
  
  /// Qualify any generic type constraints, which SourceKit gives us as inherited types.
  private static func parseInheritedTypes(rawInheritedTypes: [StructureDictionary],
                                  moduleNames: [String],
                                  rawType: RawType,
                                  rawTypeRepository: RawTypeRepository) -> Set<String> {
    var constraints = Set<String>()
    for rawInheritedType in rawInheritedTypes {
      guard let name = rawInheritedType[SwiftDocKey.name.rawValue] as? String else { continue }
      let declaredType = DeclaredType(from: name)
      let serializationContext = SerializationRequest
        .Context(moduleNames: moduleNames,
                 rawType: rawType,
                 rawTypeRepository: rawTypeRepository)
      let qualifiedTypeNameRequest = SerializationRequest(method: .moduleQualified,
                                                          context: serializationContext,
                                                          options: .standard)
      constraints.insert(declaredType.serialize(with: qualifiedTypeNameRequest))
    }
    return constraints
  }
  
  /// Manually parse any constraints defined by associated types in protocols.
  private static func parseAssociatedTypes(constraints: inout Set<String>,
                                   rawType: RawType,
                                   dictionary: StructureDictionary,
                                   moduleNames: [String],
                                   rawTypeRepository: RawTypeRepository) -> [WhereClause] {
    var whereClauses = [WhereClause]()
    let source = rawType.parsedFile.data
    guard let declaration = SourceSubstring.key.extract(from: dictionary, contents: source),
      let inferredTypeLowerBound = declaration.firstIndex(of: ":")
      else { return whereClauses }
    
    let inferredTypeStartIndex = declaration.index(after: inferredTypeLowerBound)
    let typeDeclaration = declaration[inferredTypeStartIndex...]
    
    // Associated types can also have generic type constraints using a generic `where` clause.
    let inferredType: String
    if let whereRange = typeDeclaration.range(of: #"\bwhere\b"#, options: .regularExpression) {
      let rawInferredType = typeDeclaration[..<whereRange.lowerBound]
      inferredType = String(rawInferredType.trimmingCharacters(in: .whitespacesAndNewlines))
      
      whereClauses = typeDeclaration[whereRange.upperBound...]
        .components(separatedBy: ",", excluding: .allGroups)
        .compactMap({ WhereClause(from: String($0)) })
        .map({ GenericType.qualifyWhereClause($0,
                                              containingType: rawType,
                                              moduleNames: moduleNames,
                                              rawTypeRepository: rawTypeRepository) })
    } else { // No `where` generic type constraints.
      inferredType = String(typeDeclaration.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    // Qualify all generic constraint types.
    let declaredType = DeclaredType(from: inferredType)
    let serializationContext = SerializationRequest
      .Context(moduleNames: moduleNames,
               rawType: rawType,
               rawTypeRepository: rawTypeRepository)
    let qualifiedTypeNameRequest = SerializationRequest(method: .moduleQualified,
                                                        context: serializationContext,
                                                        options: .standard)
    constraints.insert(declaredType.serialize(with: qualifiedTypeNameRequest))
    
    return whereClauses
  }
  
  /// Type constraints for associated types can contain `Self` references which need to be resolved.
  static func qualifyWhereClause(_ whereClause: WhereClause,
                                 containingType: RawType,
                                 moduleNames: [String],
                                 rawTypeRepository: RawTypeRepository) -> WhereClause {
    if whereClause.genericConstraint == "Self" {
      return WhereClause(constrainedTypeName: whereClause.constrainedTypeName,
                         genericConstraint: SerializationRequest.Constants.selfToken,
                         operator: whereClause.operator)
    }
    
    let declaredType = DeclaredType(from: whereClause.genericConstraint)
    let serializationContext = SerializationRequest
      .Context(moduleNames: moduleNames,
               rawType: containingType,
               rawTypeRepository: rawTypeRepository)
    let qualifiedTypeNameRequest = SerializationRequest(method: .moduleQualified,
                                                        context: serializationContext,
                                                        options: .standard)
    let qualifiedTypeName = declaredType.serialize(with: qualifiedTypeNameRequest)
    return WhereClause(constrainedTypeName: whereClause.constrainedTypeName,
                       genericConstraint: qualifiedTypeName,
                       operator: whereClause.operator)
  }
}