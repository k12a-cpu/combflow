import docopt, intsets, os, osproc, streams, strutils, tempfile

type
  Node = string

  GateKind = enum
    gateNot
    gateAnd
    gateOr
    gateNand
    gateNor
    gateXor

  Gate = object of RootObj
    kind: GateKind
    input1: Node
    input2: Node
    output: Node

  BlifParseError = object of Exception

proc hasTwoInputs(kind: GateKind): bool {.inline, noSideEffect.} =
  kind != gateNot
proc hasTwoInputs(gate: Gate): bool {.inline, noSideEffect.} =
  gate.kind.hasTwoInputs
proc packageSize(kind: GateKind): int {.inline, noSideEffect.} =
  if kind.hasTwoInputs:
    4
  else:
    6
proc packageSize(gate: Gate): int {.inline, noSideEffect.} =
  gate.kind.packageSize

proc raiseVal[T](e: ref Exception): T {.inline.} =
  ## Raise e, and "return" the zero value of type T to satisfy typechecking in
  ## some situations.
  raise e

proc avoidNil(s: string): string {.inline, noSideEffect.} =
  if s.isNil:
    ""
  else:
    s

proc `$`(gate: Gate): string {.noSideEffect.} =
  if gate.hasTwoInputs:
    "$1(A=$2, B=$3, Y=$4)" % [$gate.kind, gate.input1.avoidNil, gate.input2.avoidNil, gate.output.avoidNil]
  else:
    "$1(A=$2, Y=$3)" % [$gate.kind, gate.input1.avoidNil, gate.output.avoidNil]

proc readBlif(input: Stream): seq[Gate] =
  result.newSeq(0)
  var line = ""
  var lineno = 0
  while input.readLine(line):
    inc lineno
    if line.startsWith(".subckt "):
      let parts = line.split()
      let kindStr = parts[1].strip.toUpperASCII
      var gate: Gate
      gate.kind =
        case kindStr
        of "NOT":  gateNot
        of "AND":  gateAnd
        of "OR":   gateOr
        of "NAND": gateNand
        of "NOR":  gateNor
        of "XOR":  gateXor
        else:
          raiseVal[GateKind] newException(BlifParseError, "line $1: unexpected subcircuit kind '$2'" % [$lineno, kindStr])
      for part in parts[2..parts.high]:
        let equalPos = part.find('=')
        if equalPos < 0:
          raise newException(BlifParseError, "line $1: syntax error in parameters" % $lineno)
        let paramName = part[0..equalPos-1].strip.toUpperASCII
        let node = part[equalPos+1..part.high].strip
        case paramName
        of "A": gate.input1 = node
        of "B": gate.input2 = node
        of "Y": gate.output = node
        else:
          raise newException(BlifParseError, "line $1: unexpected parameter name '$2'" % [$lineno, paramName])
      result.add(gate)

proc demoteExcessInverters(gatesByKind: var array[GateKind, seq[Gate]]) =
  # All but one NOT-gate packages are guaranteed to have all 6 slots filled.
  # excessNots is the number of filled slots in the package that doesn't necessarily have all 6 slots filled.
  var excessNots = gatesByKind[gateNot].len mod 6
  # Similarly for NAND, NOR and XOR:
  let excessNands = gatesByKind[gateNand].len mod 4
  let excessNors = gatesByKind[gateNor].len mod 4
  let excessXors = gatesByKind[gateXor].len mod 4
  var freeNandSlots = (4 - excessNands) mod 4
  var freeNorSlots = (4 - excessNors) mod 4
  var freeXorSlots = (4 - excessXors) mod 4
  if excessNots <= freeNandSlots + freeNorSlots + freeXorSlots:
    # Fit the excess NOTs into NOR, NAND and XOR packages.
    while excessNots > 0 and freeNandSlots > 0:
      var gate = gatesByKind[gateNot].pop()
      gate.kind = gateNand
      gate.input2 = "1'h1"
      gatesByKind[gateNand].add(gate)
      dec excessNots
      dec freeNandSlots
    while excessNots > 0 and freeNorSlots > 0:
      var gate = gatesByKind[gateNot].pop()
      gate.kind = gateNor
      gate.input2 = "1'h0"
      gatesByKind[gateNor].add(gate)
      dec excessNots
      dec freeNorSlots
    while excessNots > 0 and freeXorSlots > 0:
      var gate = gatesByKind[gateNot].pop()
      gate.kind = gateXor
      gate.input2 = "1'h0"
      gatesByKind[gateXor].add(gate)
      dec excessNots
      dec freeXorSlots
    assert((gatesByKind[gateNot].len mod 6) == 0)

proc writeMetisGraph(output: Stream, gates: seq[Gate]): bool =
  var nets = initTable[Node, seq[int]]()
  template addGateToNet(gateNum: int, node: Node) =
    nets.mgetOrPut(node, @[]).add(gateNum)
  for gateNum, gate in gates:
    addGateToNet(gateNum, gate.input1)
    if gate.hasTwoInputs:
      addGateToNet(gateNum, gate.input2)
    addGateToNet(gateNum, gate.output)

  var neighbours = newSeq[IntSet](gates.len)
  var numEdges = 0
  for gateNum, gate in gates:
    var neighbourSet = initIntSet()
    template addNeighbours(node: Node) =
      for neighbourGateNum in nets[node]:
        neighbourSet.incl(neighbourGateNum)
    addNeighbours(gate.input1)
    if gate.hasTwoInputs:
      addNeighbours(gate.input2)
    addNeighbours(gate.output)
    neighbourSet.excl(gateNum)
    neighbours[gateNum] = neighbourSet
    inc(numEdges, neighbourSet.card)

  if numEdges == 0:
    # packing doesn't matter
    return false

  # Each edge will have been counted twice; (u,v) as well as (v,u).
  numEdges = numEdges div 2

  let numVertices = gates.len
  output.writeLine("$1 $2 000" % [$numVertices, $numEdges])
  for gateNum in 0 .. gates.high:
    for neighbourGateNum in neighbours[gateNum]:
      output.write("$1 " % $(neighbourGateNum+1))
    output.writeLine()

  return true

proc writeMetisPartitionWeights(output: Stream, gates: seq[Gate]): int =
  ## returns number of partitions
  let ps = gates[0].packageSize
  let numGates = gates.len
  let gateWeight = 1.0 / numGates.float
  let numFullPackages = numGates div ps
  output.writeLine("0 - $1 = $2" % [$(numFullPackages-1), $(gateWeight*ps.float)])
  result = numFullPackages

  let leftoverGates = numGates mod ps
  if leftoverGates != 0:
    output.writeLine("$1 = $2" % [$numFullPackages, $(gateWeight*leftoverGates.float)])
    inc result

proc dumbPartition(gates: seq[Gate]): seq[seq[Gate]] =
  if gates.len == 0:
    return @[]
  result.newSeq(0)
  let ps = gates[0].packageSize
  var i = 0
  while i < gates.len:
    let j = min(i+ps-1, gates.high)
    result.add(gates[i .. j])
    inc(i, ps)

proc partition(gates: seq[Gate]): seq[seq[Gate]] =
  if gates.len == 0:
    return @[]

  let (graphFile, graphFileName) = mkstemp(prefix = "combflow_metis_", suffix = ".graph.dat", mode = fmWrite)
  let continueWithMetis = writeMetisGraph(newFileStream(graphFile), gates)
  graphFile.close()

  if not continueWithMetis:
    removeFile(graphFileName)
    return dumbPartition(gates)

  let (weightsFile, weightsFileName) = mkstemp(prefix = "combflow_metis_", suffix = ".tpwgts.dat", mode = fmWrite)
  let numPartitions = writeMetisPartitionWeights(newFileStream(weightsFile), gates)
  weightsFile.close()
  
  if numPartitions < 2:
    removeFile(graphFileName)
    removeFile(weightsFileName)
    return dumbPartition(gates)

  let processArgs = [
    "-tpwgts", weightsFileName, # Path to file containing partition weights
    "-seed", "1",               # RNG seed (use a fixed value for deterministic results)
    graphFileName,              # Path to file containing graph specification
    $numPartitions,             # Number of partitions to produce
  ]
  let processOpts = {poEchoCmd, poUsePath, poParentStreams}
  let p = startProcess("gpmetis", args = processArgs, options = processOpts)
  defer: p.close()

  let exitCode = p.waitForExit()
  if exitCode != 0:
    echo "error: gpmetis exited with code $1" % $exitCode
    quit(1)

  let partFileName = graphFileName & ".part." & $numPartitions
  if not partFileName.existsFile:
    echo "error: failed to locate gpmetis output file (expected it to be $1)" % partFileName
    quit(1)

  let partFile = open(partFileName, mode = fmRead)
  let partStream = newFileStream(partFile)

  result.newSeq(numPartitions)
  for i in result.low .. result.high:
    result[i].newSeq(0)

  var line = ""
  var gateNum = 0
  var extra = newSeq[Gate]()
  while partStream.readLine(line):
    let partNum = line.parseInt
    if result[partNum].len < 4:
      result[partNum].add(gates[gateNum])
    else:
      extra.add(gates[gateNum])
    inc gateNum
  for gate in extra:
    var added = false
    for partNum in result.low .. result.high:
      if result[partNum].len < 4:
        result[partNum].add(gate)
        added = true
        break
    assert added

  partFile.close()

  removeFile(graphFileName)
  removeFile(weightsFileName)
  removeFile(partFileName)

proc pad(parts: var seq[seq[Gate]]) =
  if parts.len == 0:
    return

  let kind = parts[0][0].kind
  let ps = kind.packageSize
  for part in parts.mitems:
    let count = part.len
    let padding = (ps - (count mod ps)) mod ps
    for i in 1 .. padding:
      let dummyGate = Gate(
        kind: kind,
        input1: "1'h0",
        input2: if kind.hasTwoInputs: "1'h0" else: nil,
        output: "disconnected",
      )
      part.add(dummyGate)
    assert(part.len == ps)

const defaultPrefix = "autogen_inst"

proc newInstanceName(prefix: string = defaultPrefix): string =
  var counter {.global.} = 0
  result = prefix & $counter
  inc counter

proc writeAttano(output: Stream, parts: seq[seq[Gate]], prefix: string = defaultPrefix) =
  if parts.len == 0:
    return

  const classNames: array[GateKind, string] = ["NOT", "AND", "OR", "NAND", "NOR", "XOR"]

  let kind = parts[0][0].kind
  let ps = kind.packageSize
  let className = classNames[kind]

  for part in parts:
    assert((part.len mod ps) == 0)

    let instName = newInstanceName(prefix)

    if kind.hasTwoInputs:
      output.writeLine "instance $1: $2[4] (" % [instName, className]
      output.writeLine "  in0 => {$1, $2, $3, $4}," % [part[0].input1, part[1].input1, part[2].input1, part[3].input1]
      output.writeLine "  in1 => {$1, $2, $3, $4}," % [part[0].input2, part[1].input2, part[2].input2, part[3].input2]
      output.writeLine "  out => {$1, $2, $3, $4}," % [part[0].output, part[1].output, part[2].output, part[3].output]
    else:
      output.writeLine "instance $1: $2[6] (" % [instName, className]
      output.writeLine "  in => {$1, $2, $3, $4, $5, $6}," % [part[0].input1, part[1].input1, part[2].input1, part[3].input1, part[4].input1, part[5].input1]
      output.writeLine "  out => {$1, $2, $3, $4, $5, $6}," % [part[0].output, part[1].output, part[2].output, part[3].output, part[4].output, part[5].output]
    output.writeLine ");"

proc main() =
  const doc = """
pack - Takes a list of gates in BLIF format, groups them into packages and
       produces a list of 7400-series IC instances in Attano format.

Usage:
  pack [options] <infile> <outfile>

Options:
  -h, --help                          Print this help text.
  -p PREFIX, --prefix PREFIX          Prefix to use for generated Attano
                                      instances. [default: """ & defaultPrefix & """]
"""

  let args = docopt(doc)

  let inputFilename = $args["<infile>"]
  let inputFile = open(inputFilename, mode = fmRead)
  defer: inputFile.close()
  let inputStream = newFileStream(inputFile)

  let outputFilename = $args["<outfile>"]
  let outputFile = open(outputFilename, mode = fmWrite)
  defer: outputFile.close()
  let outputStream = newFileStream(outputFile)

  let prefix = $args["--prefix"]

  let gates = readBlif(inputStream)

  var gatesByKind: array[GateKind, seq[Gate]]
  for kind in gatesByKind.low .. gatesByKind.high:
    gatesByKind[kind].newSeq(0)
  for gate in gates:
    gatesByKind[gate.kind].add(gate)

  demoteExcessInverters(gatesByKind)

  for kind in gatesByKind.low .. gatesByKind.high:
    var parts = partition(gatesByKind[kind])
    pad(parts)
    writeAttano(outputStream, parts, prefix)

main()
