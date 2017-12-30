part of '../code_generator2.dart';

abstract class Context<T extends TSNode> {
  TypeManager get typeManager;

  bool get topLevel;

  bool get isAssigning;
  bool get isCascading;

  TSExpression get cascadingTarget;
  TSExpression get assigningValue;

  T translate();

  E processExpression<E extends TSExpression>(Expression expression) {
    if (expression == null) {
      return null;
    }
    return expression.accept(new ExpressionVisitor(this)) as E;
  }

  TSFunction processFunctionExpression(FunctionExpression functionExpression) {
    return processExpression<TSFunction>(functionExpression);
  }

  TSBody processBody(FunctionBody body, {bool withBrackets: false}) {
    return body.accept(new BodyVisitor(this, withBrackets: withBrackets));
  }

  Iterable<TSStatement> processBlock(Block block) {
    StatementVisitor visitor = new StatementVisitor(this);
    return block.statements
        .map((s) => processStatement(s, withVisitor: visitor))
        .where((s) => s != null);
  }

  TSStatement processStatement(Statement statement,
      {StatementVisitor withVisitor}) {
    withVisitor ??= new StatementVisitor(this);
    return statement.accept(withVisitor);
  }

  AssigningContext enterAssigning(TSExpression value) =>
      new AssigningContext(this, value);

  CascadingContext enterCascade(TSExpression target) =>
      new CascadingContext(this, target);
}

class BodyVisitor extends GeneralizingAstVisitor<TSBody> {
  Context _context;
  bool withBrackets;

  BodyVisitor(this._context, {this.withBrackets: false});

  @override
  TSBody visitBlockFunctionBody(BlockFunctionBody node) {
    return new TSBody(
        statements: _context.processBlock(node.block),
        withBrackets: withBrackets);
  }

  @override
  TSBody visitExpressionFunctionBody(ExpressionFunctionBody node) {
    return new TSBody(statements: [
      new TSReturnStatement(_context.processExpression(node.expression))
    ], withBrackets: withBrackets);
  }
}

class StatementVisitor extends GeneralizingAstVisitor<TSStatement> {
  Context _context;

  StatementVisitor(this._context);

  @override
  TSStatement visitReturnStatement(ReturnStatement node) {
    return new TSReturnStatement(_context.processExpression(node.expression));
  }

  @override
  TSStatement visitStatement(Statement node) {
    return new TSUnknownStatement(node);
  }

  @override
  TSStatement visitFunctionDeclarationStatement(
      FunctionDeclarationStatement node) {
    FunctionDeclarationContext functionDeclarationContext =
        new FunctionDeclarationContext(_context, node.functionDeclaration,
            topLevel: false);
    return functionDeclarationContext.translate();
  }

  @override
  TSStatement visitExpressionStatement(ExpressionStatement node) {
    return new TSExpressionStatement(
        _context.processExpression(node.expression));
  }

  @override
  TSStatement visitVariableDeclarationStatement(
      VariableDeclarationStatement node) {
    return new TSVariableDeclarations(node.variables.variables.map((v) =>
        new TSVariableDeclaration(
            v.name.name,
            _context.processExpression(v.initializer),
            _context.typeManager.toTsType(node.variables.type?.type))));
  }
}

class ExpressionVisitor extends GeneralizingAstVisitor<TSExpression> {
  Context _context;

  ExpressionVisitor(this._context);

  @override
  TSExpression visitIntegerLiteral(IntegerLiteral node) {
    return new TSSimpleExpression(node.value.toString());
  }

  @override
  TSExpression visitExpression(Expression node) {
    return new TSUnknownExpression(node);
  }

  @override
  TSExpression visitFunctionExpression(FunctionExpression node) {
    return new FunctionExpressionContext(_context, node).translate();
  }

  @override
  TSExpression visitSimpleStringLiteral(SimpleStringLiteral node) {
    return new TSSimpleExpression(node.toSource()); // Preserve the same quotes
  }

  @override
  TSExpression visitNullLiteral(NullLiteral node) {
    return new TSSimpleExpression('null');
  }

  @override
  TSExpression visitBinaryExpression(BinaryExpression node) {
    // Here we should check if
    // 1. we know what type is the left op =>
    //   1.1 if it's a natural type => use natural TS operator
    //   1.2 if it's another type and there's an user defined operator => use it
    // 2. use the dynamic runtime call to operator that does the above checks at runtime

    TSExpression leftExpression = _context.processExpression(node.leftOperand);
    TSExpression rightExpression =
        _context.processExpression(node.rightOperand);

    if (TypeManager.isNativeType(node.leftOperand.bestType) ||
        !node.operator.isUserDefinableOperator) {
      return new TSBinaryExpression(
          leftExpression, node.operator.lexeme.toString(), rightExpression);
    }

    if (node.leftOperand.bestType is InterfaceType) {
      InterfaceType cls = node.leftOperand.bestType as InterfaceType;
      MethodElement method = findMethod(cls, node.operator.lexeme);
      assert(method != null,
          'Operator ${node.operator} can be used only if defined in ${cls.name}');
      return new TSInvoke(
          new TSSquareExpression(
              leftExpression, _operatorName(method, node.operator)),
          [rightExpression]);
    }

    return new TSInvoke(new TSSimpleExpression('bare.invokeBinaryOperand'), [
      new TSSimpleExpression('"${node.operator.lexeme}"'),
      leftExpression,
      rightExpression
    ]);
  }

  TSExpression _operatorName(MethodElement method, Token op) {
    return new TSDotExpression(
        new TSSimpleExpression(method.enclosingElement.name),
        "OPERATOR_${op.type.name}");
  }

  @override
  TSExpression visitCascadeExpression(CascadeExpression node) {
    TSExpression target = new TSSimpleExpression('_');
    CascadingContext cascadingContext = _context.enterCascade(target);
    //CascadingVisitor cascadingVisitor = new CascadingVisitor(_context, target);
    TSBody body = new TSBody(statements: () sync* {
      yield* node.cascadeSections
          .map((e) => cascadingContext.processExpression(e))
          .map((e) => new TSExpressionStatement(e));
      yield new TSReturnStatement(target);
    }());
    return new TSInvoke(
        new TSBracketExpression(new TSFunction(
            parameters: [new TSParameter(name: '_')],
            body: body,
            returnType: _context.typeManager.toTsType(node.target.bestType))),
        [_context.processExpression(node.target)]);
  }

  @override
  TSExpression visitAssignmentExpression(AssignmentExpression node) {
    TSExpression value = _context.processExpression(node.rightHandSide);
    AssigningContext assigningContext = _context.enterAssigning(value);
    return assigningContext.processExpression(node.leftHandSide);
  }

  @override
  TSExpression visitParenthesizedExpression(ParenthesizedExpression node) {
    return new TSBracketExpression(_context.processExpression(node.expression));
  }

  @override
  TSExpression visitAsExpression(AsExpression node) {
    return new TSAsExpression(_context.processExpression(node.expression),
        _context.typeManager.toTsType(node.type.type));
  }

  @override
  TSExpression visitPropertyAccess(PropertyAccess node) {
    TSExpression target = node.isCascaded
        ? _context.cascadingTarget
        : _context.processExpression(node.target);

    // If it's actually a property
    if (node.propertyName.bestElement != null) {
      // Check if we can apply an override

      return _mayWrapInAssignament(
          new TSDotExpression(target, node.propertyName.name));
    } else {
      // Use the property accessor helper
      if (_context.isAssigning) {
        return new TSInvoke(new TSSimpleExpression('bare.writeProperty'), [
          target,
          new TSSimpleExpression('"${node.propertyName.name}"'),
          _context.assigningValue
        ]);
      } else {
        return new TSInvoke(new TSSimpleExpression('bare.readProperty'),
            [target, new TSSimpleExpression('"${node.propertyName.name}"')]);
      }
    }
  }

  TSExpression _mayWrapInAssignament(TSExpression expre) {
    if (_context.isAssigning) {
      return new TSAssignamentExpression(expre, _context.assigningValue);
    } else {
      return expre;
    }
  }
}

class AssigningContext extends Context with ChildContext {
  TSExpression _value;

  TSExpression get assigningValue => _value;
  bool get isAssigning => true;

  AssigningContext(Context parent, this._value) {
    parentContext = parent;
  }

  @override
  TSNode translate() => parentContext.translate();
}

class CascadingContext extends Context with ChildContext {
  TSExpression _cascadingTarget;

  CascadingContext(Context parent, this._cascadingTarget) {
    parentContext = parent;
  }

  @override
  TSNode translate() => parentContext.translate();

  @override
  bool get isCascading => true;

  @override
  TSExpression get cascadingTarget => _cascadingTarget;
}

MethodElement findMethod(InterfaceType tp, String methodName) {
  MethodElement m = tp.getMethod(methodName);
  if (m != null) {
    return m;
  }

  if (tp.superclass != null) {
    return findMethod(tp.superclass, methodName);
  }

  return null;
}

class TopLevelContext {
  TypeManager typeManager;

  bool get topLevel => true;

  bool get isAssigning => false;
  bool get isCascading => false;
  TSExpression get assigningValue => null;
  TSExpression get cascadingTarget => null;
}

class ChildContext {
  Context parentContext;

  TypeManager get typeManager => parentContext.typeManager;

  bool get topLevel => false;
  bool get isAssigning => parentContext.isAssigning;
  bool get isCascading => parentContext.isCascading;
  TSExpression get assigningValue => parentContext.assigningValue;
  TSExpression get cascadingTarget => parentContext.cascadingTarget;
}

/**
 * Generation Context
 */

class LibraryContext extends Context<TSLibrary> with TopLevelContext {
  LibraryElement _libraryElement;
  List<FileContext> _fileContexts;

  LibraryContext(this._libraryElement) {
    typeManager = new TypeManager(_libraryElement);
    _fileContexts = _libraryElement.units
        .map((cu) => cu.computeNode())
        .map((cu) => new FileContext(this, cu))
        .toList();
  }

  TSLibrary translate() {
    TSLibrary tsLibrary = new TSLibrary(_libraryElement.source.uri.toString());
    tsLibrary._children.addAll(_fileContexts.map((fc) => fc.translate()));

    return tsLibrary;
  }
}

class FileContext extends Context<TSFile> with ChildContext {
  CompilationUnit _compilationUnit;
  List<Context> _topLevelContexts;

  FileContext(LibraryContext parent, this._compilationUnit) {
    this.parentContext = parent;

    TopLevelDeclarationVisitor visitor = new TopLevelDeclarationVisitor(this);
    _topLevelContexts = new List();
    _topLevelContexts.addAll(_compilationUnit.declarations
        .map((f) => f.accept(visitor))
        .where((x) => x != null));
  }

  TSFile translate() {
    return new TSFile(
        _compilationUnit, _topLevelContexts.map((tlc) => tlc.translate()));
  }
}

class TopLevelDeclarationVisitor extends GeneralizingAstVisitor<Context> {
  FileContext _fileContext;

  TopLevelDeclarationVisitor(this._fileContext);

  @override
  Context visitFunctionDeclaration(FunctionDeclaration node) {
    return new FunctionDeclarationContext(_fileContext, node);
  }
}

class FunctionExpressionContext extends Context<TSFunction> with ChildContext {
  FunctionExpression _functionExpression;

  FunctionExpressionContext(Context parent, this._functionExpression) {
    parentContext = parent;
  }

  TSFunction translate() {
    List<TSTypeParameter> typeParameters;

    if (_functionExpression.typeParameters != null) {
      typeParameters = new List.from(_functionExpression
          .typeParameters.typeParameters
          .map((t) => new TSTypeParameter(
              t.name.name, typeManager.toTsType(t.bound?.type))));
    } else {
      typeParameters = null;
    }

    // arguments
    FormalParameterCollector parameterCollector =
        new FormalParameterCollector(this);
    (_functionExpression.parameters?.parameters ?? []).forEach((p) {
      p.accept(parameterCollector);
    });

    // body
    TSBody body = processBody(_functionExpression.body, withBrackets: false);

    return new TSFunction(
        topLevel: topLevel,
        typeParameters: typeParameters,
        parameters: new List.from(parameterCollector.tsParameters),
        defaults: parameterCollector.defaults,
        namedDefaults: parameterCollector.namedDefaults,
        body: body);
  }
}

const String NAMED_ARGUMENTS = '_namedArguments';

class FormalParameterCollector extends GeneralizingAstVisitor {
  Context _context;

  FormalParameterCollector(this._context);

  Map<String, TSExpression> defaults = {};
  Map<String, TSExpression> namedDefaults = {};
  List<TSParameter> parameters = [];
  TSInterfaceType namedType;

  Iterable<TSParameter> get tsParameters sync* {
    yield* parameters;
    if (namedType != null) {
      yield new TSParameter(
          name: NAMED_ARGUMENTS, type: namedType, optional: true);
    }
  }

  @override
  visitDefaultFormalParameter(DefaultFormalParameter node) {
    super.visitDefaultFormalParameter(node);
    if (node.defaultValue == null) {
      return;
    }
    if (node.kind == ParameterKind.NAMED) {
      namedDefaults[node.identifier.name] =
          _context.processExpression(node.defaultValue);
    } else {
      defaults[node.identifier.name] =
          _context.processExpression(node.defaultValue);
    }
  }

  @override
  visitFormalParameter(FormalParameter node) {
    if (node.kind == ParameterKind.NAMED) {
      namedType ??= new TSInterfaceType();
      namedType.fields[node.identifier.name] =
          _context.typeManager.toTsType(node.element.type);
    } else {
      parameters.add(new TSParameter(
          name: node.identifier.name,
          type: _context.typeManager.toTsType(node.element.type),
          optional: node.kind.isOptional));
    }
  }
}

class FunctionDeclarationContext extends Context<TSFunction> with ChildContext {
  FunctionDeclaration _functionDeclaration;
  bool topLevel;

  TSType returnType;

  FunctionDeclarationContext(Context parentContext, this._functionDeclaration,
      {this.topLevel = true}) {
    this.parentContext = parentContext;
  }

  @override
  TSFunction translate() {
    return processFunctionExpression(_functionDeclaration.functionExpression)
      ..name = _functionDeclaration.name.name
      ..topLevel = topLevel
      ..returnType = parentContext.typeManager
          .toTsType(_functionDeclaration?.returnType?.type);
  }
}

class ClassContext extends Context<TSClass> with ChildContext {
  ClassContext(Context parent) {
    parentContext = parent;
  }

  @override
  TSClass translate() {}
}

class MethodContext extends Context<TSNode> with ChildContext {
  ClassContext _classContext;

  @override
  TSNode translate() {
    // TODO: implement translate
  }
}
