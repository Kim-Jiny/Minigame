import 'package:flutter/material.dart';
import '../games/gomoku/gomoku_screen.dart';
import '../games/hexagon/hexagon_screen.dart';
import '../games/hunmin/hunmin_screen.dart';
import '../games/infinite_tictactoe/infinite_tictactoe_screen.dart';
import '../games/pyramid/pyramid_screen.dart';
import '../games/reaction/reaction_screen.dart';
import '../games/rps/rps_screen.dart';
import '../games/sequence/sequence_screen.dart';
import '../games/speedtap/speedtap_screen.dart';
import '../games/stroop/stroop_screen.dart';
import '../games/tictactoe/tictactoe_screen.dart';
import '../games/numberbattle/numberbattle_screen.dart';
import '../games/cardflip/cardflip_screen.dart';
import '../utils/game_catalog.dart';

class GameRoutes {
  const GameRoutes._();

  static Map<String, WidgetBuilder> buildNamedRoutes() {
    return {
      GameCatalog.routeFor('tictactoe'): (_) => const TicTacToeScreen(),
      GameCatalog.routeFor('infinite_tictactoe'): (_) =>
          const InfiniteTicTacToeScreen(),
      GameCatalog.routeFor('gomoku'): (_) => const GomokuScreen(),
      GameCatalog.routeFor('reaction'): (_) => const ReactionScreen(),
      GameCatalog.routeFor('rps'): (_) => const RpsScreen(),
      GameCatalog.routeFor('speedtap'): (_) => const SpeedTapScreen(),
      GameCatalog.routeFor('sequence'): (_) => const SequenceScreen(),
      GameCatalog.routeFor('stroop'): (_) => const StroopScreen(),
      GameCatalog.routeFor('hexagon'): (_) => const HexagonScreen(),
      GameCatalog.routeFor('pyramid'): (_) => const PyramidScreen(),
      GameCatalog.routeFor('hunmin'): (_) => const HunminScreen(),
      GameCatalog.routeFor('numberbattle'): (_) => const NumberBattleScreen(),
      GameCatalog.routeFor('cardflip'): (_) => const CardFlipScreen(),
    };
  }

  static Widget? buildGameScreen(String gameType, {bool isRanked = false}) {
    switch (gameType) {
      case 'tictactoe':
        return TicTacToeScreen(isRanked: isRanked);
      case 'infinite_tictactoe':
        return InfiniteTicTacToeScreen(isRanked: isRanked);
      case 'gomoku':
        return GomokuScreen(isRanked: isRanked);
      case 'reaction':
        return ReactionScreen(isRanked: isRanked);
      case 'rps':
        return RpsScreen(isRanked: isRanked);
      case 'speedtap':
        return SpeedTapScreen(isRanked: isRanked);
      case 'sequence':
        return SequenceScreen(isRanked: isRanked);
      case 'stroop':
        return StroopScreen(isRanked: isRanked);
      case 'hexagon':
        return isRanked ? null : const HexagonScreen();
      case 'pyramid':
        return isRanked ? null : const PyramidScreen();
      case 'hunmin':
        return isRanked ? null : const HunminScreen();
      case 'numberbattle':
        return NumberBattleScreen(isRanked: isRanked);
      case 'cardflip':
        return CardFlipScreen(isRanked: isRanked);
      default:
        return null;
    }
  }
}
