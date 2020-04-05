import 'dart:typed_data';

import 'assembly.dart';
import 'instruction.dart';
import 'token.dart';

List<String> registers = [
  "\$zero",
  "\$at",
  "\$v0",
  "\$v1",
  "\$a0",
  "\$a1",
  "\$a2",
  "\$a3",
  "\$t0",
  "\$t1",
  "\$t2",
  "\$t3",
  "\$t4",
  "\$t5",
  "\$t6",
  "\$t7",
  "\$s0",
  "\$s1",
  "\$s2",
  "\$s3",
  "\$s4",
  "\$s5",
  "\$s6",
  "\$s7",
  "\$t8",
  "\$t9",
  "\$k0",
  "\$k1",
  "\$gp",
  "\$sp",
  "\$fp",
  "\$ra"
];

int getRegister(String name) {
  return registers.indexOf(name);
}

class SectionHeader {
  String name;
  int type;
  int offset;
  int size;

  SectionHeader(this.name, this.type, this.offset);
}

class Assembler {
  Assembly assembly;
  Uint8List buffer;
  int offset = 0;
  List<SectionHeader> headers = [];
  int entry = 0;
  int sha = 0;
  int strt  = 0;

  Assembler(Assembly program) {
    this.assembly = program;
    int size = assembly.instructions.length * 4 + assembly.dataSize;
    buffer = new Uint8List(size * 10);
    offset = 15; // File header length
  }

  Uint8List assemble() {
    this.resolveLabels();

    this.entry = this.offset;
    if (this.assembly.labels.containsKey("main")) {
      this.entry += this.assembly.labels["main"].address;
    }

    this.emitInstructions();
    this.emitInstructionHeader();
    this.emitDataSection();
    this.emitStringTable();
    this.emitSectionHeaders();
    this.emitFileHeader();

    return this.buffer;
  }

  void emitInstructionHeader() {
    SectionHeader header = new SectionHeader(".text", 0x01, 15);
    header.size = this.offset - 15;

    headers.add(header);
  }

  void resolveLabels() {
    for (Label label in assembly.labels.values) {
      if (label.segment == Segment.SGT_TEXT) {
        label.address *= 4;
      }
    }
  }

  void emitStringTable() {
    SectionHeader string = new SectionHeader(".string", 0x02, this.offset);

    this.emitByte(0);
    this.emitByte(0);

    string.size = this.offset - string.offset;
    headers.add(string);
  }

  void emitDataSection() {
    SectionHeader data = new SectionHeader(".data", 0x04, this.offset);

    Map<String, Function> map = {
      ".byte": this.emitByte,
      ".half": this.emitHalf,
      ".word": this.emitWord
    };

    for (Directive directive in this.assembly.directives) {
      switch(directive.name) {
        case ".byte":
        case ".half":
        case ".word": {
          for(int i = 0; i < directive.operands.length; i++) {
            map[directive.name](directive.operands[i]);
          }
          break;
        }
        case ".ascii": {
          for(int i = 0; i < directive.operands.length; i++) {
            this.emitBytes(directive.operands[i].toString().codeUnits);
          }
          break;
        }
        case ".asciiz": {
          for(int i = 0; i < directive.operands.length; i++) {
            this.emitBytes(directive.operands[i].toString().codeUnits + [0]);
          }
          break;
        }
      }
    }

    data.size = this.offset - data.offset;

    headers.add(data);
  }

  void emitSectionHeaders() {
    this.sha = this.offset;
    for(SectionHeader header in this.headers) {
      this.emitHalf(0);
      this.emitByte(header.type);
      this.emitWord(header.offset);
      this.emitWord(header.size);
    }
  }

  void emitFileHeader() {
    int length = this.offset;

    this.offset = 0;
    this.emitByte(0x10);
    this.emitBytes("LEF".codeUnits);
    this.emitBytes([0x01, 0x00]); // Writes major and minor version;
    this.emitWord(this.entry);
    this.emitWord(this.sha);
    this.emitByte(headers.length);

    this.offset = length;
  }

  void emitInstructions() {
    for (Instruction instr in assembly.instructions) {
      switch (instr.name) {
        case "add":
        case "addu":
        case "and":
        case "nor":
        case "or":
        case "sub":
        case "subu":
        case "xor":
        case "slt":
        case "sltu": {
            int tgt = instr.rt.value;
            if (instr.rt.type == TokenType.T_SCALAR) {
              // addi $at, $zero, immed
              tgt = getRegister("\$at");
              this.emitImmediate("addiu", 0x00, tgt, instr.rt.value);
            }
            this.emitSpecial(instr.name, instr.rs.value, tgt, instr.rd.value, 0x00);
            break;
          }
        case "addi":
        case "addiu":
        case "andi":
        case "ori":
        case "xori":
        case "slti":
        case "sltiu": {
          this.emitImmediate(instr.name, instr.rs.value, instr.rt.value, instr.immed.value);
          break;
        }
        case "div":
        case "divu":
        case "mult":
        case "multu": {
          this.emitSpecial(instr.name, instr.rs.value, instr.rt.value, 0x00, 0x00);
          break;
        }
        case "neg":
        case "negu": {
          this.emitSpecial(instr.name.endsWith("u") ? "subu" : "sub", getRegister("\$zero"), instr.rt.value, instr.rs.value, 0x00);
          break;
        }
        case "rem":
        case "remu": {
          // remu rd, rs, rt -> divu rs, rt ; mfhi rd
          var tgt = instr.rt.value;
          if (instr.rt.type == TokenType.T_SCALAR) {
            // addi $at, $zero, immed
            tgt = getRegister("\$at");
            this.emitImmediate("addiu", 0x00, tgt, instr.rt.value);
          }
          this.emitSpecial(instr.name.endsWith("u") ? "divu" : "div", instr.rs.value, tgt, 0x00, 0x00);
          this.emitSpecial("mfhi", 0x00, 0x00, instr.rd.value, 0x00);
          break;
        }
        case "sll":
        case "sra":
        case "srl": {
          this.emitSpecial(instr.name, 0x00, instr.rs.value, instr.rt.value, instr.immed.value);
          break;
        }
        case "sllv":
        case "srav":
        case "srlv": {
          this.emitSpecial(instr.name, instr.rt.value, instr.rs.value, instr.rd.value, 0x00);
          break;
        }
        case "li": {
          this.emitImmediate("addiu", 0x00, instr.rt.value, instr.immed.value);
          break;
        }
        case "b":
        case "j":
        case "jal": {
          Token label = instr.immed;
          int address;
          if (label.type == TokenType.T_IDENTIFIER) {
            if(!this.assembly.labels.containsKey(label.value)) {
              throw new AssemblerError(label, "Undefined label '${label.value}'.");
            }

            address = this.assembly.labels[label.value].address >> 2;
          } else {
            address = ((label.value as int) >> 2) & 0x03FFFFFF;
          }

          this.emitJInstruction(OpCodes[instr.name == "b" ? "j" : instr.name], address);
          break;
        }
        case "beq":
        case "bne": {
          // Adjust bindings
          Token tmp = instr.rs; instr.rs = instr.rt; instr.rt = tmp;

          Token label = instr.immed;
          int address;
          if (label.type == TokenType.T_IDENTIFIER) {
            if(!this.assembly.labels.containsKey(label.value)) {
              throw new AssemblerError(label, "Undefined label '${label.value}'.");
            }

            address = this.assembly.labels[label.value].address >> 2;
          } else {
            address = ((label.value as int) >> 2) & 0x03FFFFFF;
          }

          var tgt = instr.rt.value;
          if (instr.rt.type == TokenType.T_SCALAR) {
            // addiu $at, $zero, immed
            tgt = getRegister("\$at");
            this.emitImmediate("addiu", 0x00, tgt, instr.rt.value);
          }

          this.emitImmediate(instr.name, instr.rs.value, tgt, address - this.offset - 1);
          break;
        }
        case "blt": {
          // blt rs, rt, label -> slt $at, rs, rt ; bne $at, $zero, label;

          // slt $at, rs, rt
          var tgt = instr.rt.value;
          if (instr.rt.type == TokenType.T_SCALAR) {
            // addiu $at, $zero, immed
            tgt = getRegister("\$at");
            this.emitImmediate("addiu", 0x00, tgt, instr.rt.value);
          }

          this.emitSpecial("slt", instr.rs.value, tgt, getRegister("\$at"), 0x00);

          // bne $at, $zero, label
          int address;
          var label = instr.immed;
          if (label.type == TokenType.T_IDENTIFIER) {
            if(!this.assembly.labels.containsKey(label.value)) {
              throw new AssemblerError(label, "Undefined label '${label.value}'.");
            }

            address = this.assembly.labels[label.value].address >> 2;
          } else {
            address = ((label.value as int) >> 2) & 0x03FFFFFF;
          }
          this.emitImmediate("bne", getRegister("\$at"), 0x00, address - this.offset - 1);
          break;
        }
        case "jr": {
          this.emitSpecial("jr", instr.rs.value, 0x00, 0x00, 0x00);
          break;
        }
        case "jalr": {
          this.emitSpecial("jalr", instr.rt.value, 0x00, instr.rs.value, 0x00);
          break;
        }
        case "la": {
          Token label = instr.immed;
          int address;
          if(!this.assembly.labels.containsKey(label.value)) {
            throw new AssemblerError(label, "Undefined label '${label.value}'.");
          }

          address = this.assembly.labels[label.value].address;
          // addiu $rd, $gp, address
          this.emitImmediate("addiu", getRegister("\$gp"), instr.rt.value, address);
          break;
        }
        case "lb":
        case "lbu":
        case "lh":
        case "lhu":
        case "lw":
        case "sb":
        case "sh":
        case "sw": {
          this.emitImmediate(instr.name, instr.rs.value, instr.rt.value, instr.immed.value);
          break;
        }
        case "move": {
          this.emitSpecial("add", 0x00, instr.rt.value, instr.rs.value, 0x00);
          break;
        }
        case "mfhi":
        case "mflo": {
          this.emitSpecial(instr.name, 0x00, 0x00, instr.rd.value, 0x00);
          break;
        }
        case "mthi":
        case "mtlo": {
          this.emitSpecial(instr.name, instr.rs.value, 0x00, 0x00, 0x00);
          break;
        }
        case "syscall": {
          this.emitSpecial("syscall", 0x00, 0x00, 0x00, 0x00);
          break;
        }
        default:
          throw new AssemblerError(null, "Instruction '${instr.name}' is not yet supported.");
      }
    }
  }

  void emitJInstruction(int code, int immediate) {
    int instr = (code << 26) | immediate;
    this.emitWord(instr);
  }

  void emitSpecial(String code, int rs, int rt, int rd, int shmt) {
    int instr = (0x00 << 26) |
        (rs << 21) |
        (rt << 16) |
        (rd << 11) |
        (shmt << 6) |
        (OpCodes[code] & 0x3F);
    this.emitWord(instr);
  }

  void emitImmediate(String code, int rs, int rt, int immed) {
    int instr = (OpCodes[code] << 26) | (rs << 21) | (rt << 16) | (immed & 0xFFFF);
    this.emitWord(instr);
  }

  void emitByte(int byte) {
    this.buffer[offset++] = byte;
  }

  void emitBytes(List<int> bytes) {
    this.buffer.setAll(offset, bytes);
    offset += bytes.length;
  }

  void emitHalf(int half) {
    emitByte(half >> 0x08);
    emitByte(half);
  }

  void emitWord(int word) {
    emitByte(word >> 0x18);
    emitByte(word >> 0x10);
    emitByte(word >> 0x08);
    emitByte(word);
  }
}

class AssemblerError {
  String message;
  Token token;

  AssemblerError(this.token, this.message);
}