import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart' as an;
import 'package:path/path.dart' as path;
import 'package:args/args.dart';

class Ctags {
  ArgResults options;

  // /./ in dart/js does not match newlines, /[^]/ matches . + \n
  RegExp klass = RegExp(r'^[^]+?($|{)');
  RegExp enumeration = RegExp(r'^[^]+?($|{)');
  RegExp miXin = RegExp(r'^[^]+?($|{)');
  RegExp constructor = RegExp(r'^[^]+?($|{|;)');
  RegExp method = RegExp(r'^[^]+?($|{|;|\=>)');

  Ctags(this.options);

  String _parseFieldType(String input) {
    // const int test = 1;
    // final List<Map<String, dynamic>> list = [{'a': 1}];
    var leftHandSide = input.split('=')[0];

    // const int test
    // final List<Map<String, dynamic>> list
    var varTypeList = leftHandSide
        .split(' ')
        .where((s) => s != 'const' && s != 'final' && s != 'static')
        .join(' ')
        .trim()
        .split(' ');

    // [int, test]
    // [List<Map<String,, dynamic>>, list]
    varTypeList.removeLast();

    // [int]
    // [List<Map<String, dynamic>>]
    return varTypeList.join(' ');
  }

  void generate() {
    Iterable<String> dirs;

    if (options.rest.isEmpty) {
      dirs = ['.'];
    } else {
      dirs = options.rest;
    }

    final lines = <String>[
      '!_TAG_FILE_FORMAT\t2\t/extended format; --format=1 will not append ;" to lines/',
      '!_TAG_FILE_SORTED\t1\t/0=unsorted, 1=sorted, 2=foldcase/'
    ];

    Future.wait(dirs.map(addFileSystemEntity))
        .then((Iterable<Iterable<Iterable<String>>> files) {
      files.forEach((Iterable<Iterable<String>> file) {
        file.forEach((Iterable<String> fileLines) => lines.addAll(fileLines));
      });

      if (!(options['skip-sort'] as bool)) {
        lines.sort();
      }
      if (options['output'] != null) {
        File(options['output'] as String).writeAsString(lines.join('\n'));
      } else {
        print(lines.join('\n'));
      }
    });
  }

  Future<Iterable<Iterable<String>>> addFileSystemEntity(String name) async {
    final type = FileSystemEntity.typeSync(name);

    if (type == FileSystemEntityType.directory) {
      return Future.wait(await Directory(name)
          .list(recursive: true, followLinks: options['follow-links'] as bool)
          .map((file) async {
        if (file is File && path.extension(file.path) == '.dart') {
          return await parseFile(file);
        } else {
          return <String>[];
        }
      }).toList());
    } else if (type == FileSystemEntityType.file) {
      return Future.value([await parseFile(File(name))]);
    } else if (type == FileSystemEntityType.link &&
        options['follow-links'] as bool) {
      return addFileSystemEntity(Link(name).targetSync());
    } else {
      return Future.value([]);
    }
  }

  Future<Iterable<String>> parseFile(File file) async {
    if (!(options['include-hidden'] as bool) &&
        path.split(file.path).any((name) => name[0] == '.' && name != '.')) {
      return [];
    }

    String root;
    if (options['output'] != null) {
      root = path.relative(path.dirname(options['output'] as String));
    } else {
      root = '.';
    }

    final lines = <List<String>>[];
    ParseStringResult result;
    CompilationUnit unit;
    try {
      result =
          an.parseFile(path: file.path, featureSet: FeatureSet.fromEnableFlags([]));
      unit = result.unit;
    } catch (e) {
      print('ERROR: unable to generate tags for ${file.path}');
      return lines.map((line) => line.join('\t').trimRight());
    }

    // import, export, part, part of, library directives
    await Future.forEach(unit.directives, (Directive d) async {
      String tag, type, display;
      switch (d.keyword.toString()) {
        case 'import':
          tag = 'i';
          type = d.toString().contains(' as ')
              ? 'as ' + d.toString().split(' as ')[1].split(';')[0]
              : '';
          display = '${d.toString().split("'")[1]}';
          break;
        case 'export':
          tag = 't';
          type = '';

          var exportStr = d.toString().split(' ');
          if (exportStr.isNotEmpty) {
            display = exportStr[1].replaceAll(RegExp(r'.$'), '');
          }

          break;
        case 'part':
          final partOf = d.toString().contains(' of ');
          tag = partOf ? 'p' : 'P';
          type = '';
          if (partOf) {
            String partOfString;

            final lines =
                utf8.decoder.bind(file.openRead()).transform(LineSplitter());
            await for (final line in lines) {
              if (line.contains('part of')) {
                partOfString = line;
                break;
              }
            }

            if (partOfString.isNotEmpty) {
              display = partOfString.split("'")[1];
            }
          } else {
            display = '${d.toString().split("'")[1]}';
          }

          break;
        case 'library':
          tag = 'l';
          type = '';

          var libraryStr = d.toString().split(' ');
          if (libraryStr.isNotEmpty) {
            display = libraryStr[1].replaceAll(RegExp(r'.$'), '');
          }

          break;
        default:
          // not handled
          return;
      }

      lines.add([
        display,
        path.relative(file.path, from: root),
        '/^;"',
        tag,
        options['line-numbers'] as bool
            ? 'line:${unit.lineInfo.getLocation(d.offset).lineNumber}'
            : '',
        'type:$type'
      ]);
    });

    unit.declarations.forEach((declaration) {
      if (declaration is MixinDeclaration) {
        lines.add([
          declaration.name.name,
          path.relative(file.path, from: root),
          '/${miXin.matchAsPrefix(declaration.toSource())[0]}/;"',
          'x',
          'access:${declaration.name.name[0] == '_' ? 'private' : 'public'}',
          options['line-numbers'] as bool
              ? 'line:${unit.lineInfo.getLocation(declaration.offset).lineNumber}'
              : '',
          'type:mixin',
        ]);

        declaration.members.forEach((member) {
          if (member is ConstructorDeclaration) {
            String name;
            int offset;
            if (member.name == null) {
              name = declaration.name.name;
              offset = declaration.offset;
            } else {
              name = member.name.name;
              offset = member.offset;
            }

            lines.add([
              name,
              path.relative(file.path, from: root),
              '/${constructor.matchAsPrefix(member.toSource())[0]}/;"',
              'r',
              'access:${name[0] == '_' ? 'private' : 'public'}',
              options['line-numbers'] as bool
                  ? 'line:${unit.lineInfo.getLocation(offset).lineNumber}'
                  : '',
              'mixin:{declaration.name}',
              'signature:${member.parameters.toString()}',
            ]);
          } else if (member is FieldDeclaration) {
            member.fields.variables.forEach((variable) {
              var memberSource = member.toSource();

              lines.add([
                variable.name.name,
                path.relative(file.path, from: root),
                '/${memberSource}/;"',
                'f',
                'access:${variable.name.name[0] == '_' ? 'private' : 'public'}',
                options['line-numbers'] as bool
                    ? 'line:${unit.lineInfo.getLocation(member.offset).lineNumber}'
                    : '',
                'mixin:{declaration.name}',
                'type:${_parseFieldType(memberSource)}'
              ]);
            });
          } else if (member is MethodDeclaration) {
            var tag = 'm';
            if (member.isStatic) {
              tag = 'M';
            }
            // better if static is least preferred
            if (member.isOperator) {
              tag = 'o';
            }
            if (member.isGetter) {
              tag = 'g';
            }
            if (member.isSetter) {
              tag = 's';
            }
            if (member.isAbstract) {
              tag = 'a';
            }

            var memberSource = member.toSource();

            lines.add([
              member.name.name,
              path.relative(file.path, from: root),
              '/${method.matchAsPrefix(memberSource)[0]}/;"',
              tag,
              'access:${member.name.name[0] == '_' ? 'private' : 'public'}',
              options['line-numbers'] as bool
                  ? 'line:${unit.lineInfo.getLocation(member.offset).lineNumber}'
                  : '',
              'mixin:${declaration.name}',
              'signature:${tag == 'g' ? '' : member.parameters.toString()}',
              'type:${member.returnType.toString()}'
            ]);
          }
        });
      } else if (declaration is FunctionDeclaration) {
        lines.add([
          declaration.name.name,
          path.relative(file.path, from: root),
          '/^;"',
          'F',
          'access:${declaration.name.name[0] == '_' ? 'private' : 'public'}',
          options['line-numbers'] as bool
              ? 'line:${unit.lineInfo.getLocation(declaration.offset).lineNumber}'
              : '',
          'signature:${declaration.functionExpression.parameters.toString()}',
          'type:${declaration.returnType.toString()}'
        ]);
      } else if (declaration is TopLevelVariableDeclaration) {
        var varType = declaration.variables.type.toString();
        var isConst = declaration.variables.isConst;

        declaration.variables.variables.asMap().values.forEach((v) {
          lines.add([
            v.name.name,
            path.relative(file.path, from: root),
            '/^;"',
            '${isConst ? 'C' : 'v'}',
            'access:${v.name.name[0] == '_' ? 'private' : 'public'}',
            options['line-numbers'] as bool
                ? 'line:${unit.lineInfo.getLocation(declaration.offset).lineNumber}'
                : '',
            'type:${varType == 'null' ? isConst ? '' : declaration.variables.keyword.toString() : varType}'
          ]);
        });
      } else if (declaration is EnumDeclaration) {
        lines.add([
          declaration.name.name,
          path.relative(file.path, from: root),
          '/${enumeration.matchAsPrefix(declaration.toSource())[0]}/;"',
          'E',
          'access:${declaration.name.name[0] == '_' ? 'private' : 'public'}',
          options['line-numbers'] as bool
              ? 'line:${unit.lineInfo.getLocation(declaration.offset).lineNumber}'
              : '',
          'type:enum',
        ]);
        declaration.constants.forEach((constant) {
          String name;
          int offset;

          if (constant.name == null) {
            name = declaration.name.name;
            offset = declaration.offset;
          } else {
            name = constant.name.name;
            offset = constant.offset;
          }
          lines.add([
            name,
            path.relative(file.path, from: root),
            '/${enumeration.matchAsPrefix(constant.toSource())[0]}/;"',
            'e',
            options['line-numbers'] as bool
                ? 'line:${unit.lineInfo.getLocation(offset).lineNumber}'
                : '',
            'enum:${declaration.name}',
          ]);
        });
      } else if (declaration is ClassDeclaration) {
        lines.add([
          declaration.name.name,
          path.relative(file.path, from: root),
          '/${klass.matchAsPrefix(declaration.toSource())[0]}/;"',
          'c',
          'access:${declaration.name.name[0] == '_' ? 'private' : 'public'}',
          options['line-numbers'] as bool
              ? 'line:${unit.lineInfo.getLocation(declaration.offset).lineNumber}'
              : '',
          'type:${declaration.isAbstract ? 'abstract ' : ''}class',
        ]);
        declaration.members.forEach((member) {
          if (member is ConstructorDeclaration) {
            String name;
            int offset;
            if (member.name == null) {
              name = declaration.name.name;
              offset = declaration.offset;
            } else {
              name = member.name.name;
              offset = member.offset;
            }

            lines.add([
              name,
              path.relative(file.path, from: root),
              '/${constructor.matchAsPrefix(member.toSource())[0]}/;"',
              'r',
              'access:${name[0] == '_' ? 'private' : 'public'}',
              options['line-numbers'] as bool
                  ? 'line:${unit.lineInfo.getLocation(offset).lineNumber}'
                  : '',
              'class:${declaration.name}',
              'signature:${member.parameters.toString()}',
            ]);
          } else if (member is FieldDeclaration) {
            member.fields.variables.forEach((variable) {
              var memberSource = member.toSource();

              lines.add([
                variable.name.name,
                path.relative(file.path, from: root),
                '/${memberSource}/;"',
                'f',
                'access:${variable.name.name[0] == '_' ? 'private' : 'public'}',
                options['line-numbers'] as bool
                    ? 'line:${unit.lineInfo.getLocation(member.offset).lineNumber}'
                    : '',
                'class:${declaration.name}',
                'type:${_parseFieldType(memberSource)}'
              ]);
            });
          } else if (member is MethodDeclaration) {
            var tag = 'm';
            if (member.isStatic) {
              tag = 'M';
            }
            // better if static is least preferred
            if (member.isOperator) {
              tag = 'o';
            }
            if (member.isGetter) {
              tag = 'g';
            }
            if (member.isSetter) {
              tag = 's';
            }
            if (member.isAbstract) {
              tag = 'a';
            }

            var memberSource = member.toSource();

            lines.add([
              member.name.name,
              path.relative(file.path, from: root),
              '/${method.matchAsPrefix(memberSource)[0]}/;"',
              tag,
              'access:${member.name.name[0] == '_' ? 'private' : 'public'}',
              options['line-numbers'] as bool
                  ? 'line:${unit.lineInfo.getLocation(member.offset).lineNumber}'
                  : '',
              'class:${declaration.name}',
              'signature:${tag == 'g' ? '' : member.parameters.toString()}',
              'type:${member.returnType.toString()}'
            ]);
          }
        });
      }
    });
    // eliminate \t string termination
    return lines.map((line) => line.join('\t').trimRight());
  }
}

void main([List<String> args]) {
  final parser = ArgParser();
  parser.addOption('output',
      abbr: 'o', help: 'Output file for tags (default: stdout)', valueHelp: 'FILE');
  parser.addFlag('follow-links',
      help: 'Follow symbolic links (default: false)', negatable: false);
  parser.addFlag('include-hidden',
      help: 'Include hidden directories (default: false)', negatable: false);
  parser.addFlag('line-numbers',
      abbr: 'l',
      help: 'Add line numbers to extension fields (default: false)',
      negatable: false);
  parser.addFlag('skip-sort',
      help: 'Skip sorting the output (default: false)', negatable: false);
  parser.addFlag('help', abbr: 'h', help: 'Show this help', negatable: false);
  final options = parser.parse(args);
  if (options['help'] as bool) {
    print(
        'Usage:\n\tdart_ctags [OPTIONS] [FILES...]\n\tpub global run dart_ctags:tags [OPTIONS] [FILES...]\n');
    print(parser.usage);
    exit(0);
  }
  Ctags(options).generate();
}
