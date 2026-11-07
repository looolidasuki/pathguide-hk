import 'cross_floor_contract.dart';

const mockGround = FloorRef('sample-building', 'floor-g', 'G');
const mockThird = FloorRef('sample-building', 'floor-3', '3F');
const mockSecond = FloorRef('sample-building', 'floor-2', '2F');

FloorRoute crossFloorFixture({ConnectorMode mode = ConnectorMode.elevator}) =>
    FloorRoute(
      id: 'p0-${mode.name}',
      version: 1,
      nodes: const [
        FloorNode('g-entry', mockGround, '地下入口', 'Ground entrance'),
        FloorNode('g-connector', mockGround, '地下轉層入口', 'Ground connector'),
        FloorNode('3-exit', mockThird, '三樓出口', 'Third-floor exit'),
        FloorNode('3-room', mockThird, '三樓課室', 'Third-floor classroom'),
      ],
      edges: [
        const FloorEdge('g-entry', 'g-connector', ConnectorMode.walk),
        FloorEdge(
          'g-connector',
          '3-exit',
          mode,
          connectorId: 'sample-connector',
        ),
        const FloorEdge('3-exit', '3-room', ConnectorMode.walk),
      ],
    );

/// Explicitly frozen synthetic time for human-operated offline buttons.
/// Tests advance time independently; this is not a live walking sensor clock.
class MockJourneyClock {
  Duration now = Duration.zero;
  Duration elapsed() => now;
  void advance(Duration by) => now += by;
}
