from logging import root
import botbowl
from botbowl.core import Action, Agent
import numpy as np
from copy import deepcopy
import random
import time


class Node:
    def __init__(self, action=None, parent=None):
        self.parent = parent
        self.children = []
        self.action = action
        self.evaluations = []

        self.n_wins = 0
        self.n_simulations = 0

    def num_visits(self):
        return len(self.evaluations)

    def visit(self, score):
        self.evaluations.append(score)

    def score(self):
        return np.average(self.evaluations)


class SearchBot(botbowl.Agent):

    def __init__(self, name, seed=None):
        super().__init__(name)
        self.my_team = None
        self.rnd = np.random.RandomState(seed)

    def new_game(self, game, team):
        self.my_team = team

    def act(self, game: botbowl.core.game.Game):
        game_copy = deepcopy(game)
        game_copy.enable_forward_model()
        game_copy.home_agent.human = True
        game_copy.away_agent.human = True
        root_step = game_copy.get_step()
        root_node = Node()

        available_actions = [elem.action_type for elem in game_copy.get_available_actions()]
        print(available_actions)
        input()

        # handle heads or tail
        if botbowl.ActionType.HEADS in available_actions or botbowl.ActionType.TAILS in available_actions:
            return np.random.choice([Action(botbowl.ActionType.HEADS), Action(botbowl.ActionType.TAILS)])

        # handle kick or receive
        if botbowl.ActionType.KICK in available_actions or botbowl.ActionType.RECEIVE in available_actions:
            return np.random.choice([Action(botbowl.ActionType.KICK), Action(botbowl.ActionType.RECEIVE)])

        if botbowl.ActionType.PLACE_PLAYER in available_actions or botbowl.ActionType.END_SETUP in available_actions or botbowl.ActionType.SETUP_FORMATION_SPREAD in available_actions or botbowl.ActionType.SETUP_FORMATION_WEDGE in available_actions:
            available_actions.remove(botbowl.ActionType.PLACE_PLAYER)
            for elem in game_copy.get_players_on_pitch(team=self.my_team):
                return Action(botbowl.ActionType.END_SETUP)
            available_actions.remove(botbowl.ActionType.END_SETUP)
            return Action(np.random.choice(available_actions))
            


        for action_choice in game_copy.get_available_actions():
            print(f'action_choice: {action_choice}')
            if action_choice.action_type == botbowl.ActionType.PLACE_PLAYER:
                continue

            for player in action_choice.players:
                root_node.children.append(Node(Action(action_choice.action_type, player=player), parent=root_node))
            for position in action_choice.positions:
                root_node.children.append(Node(Action(action_choice.action_type, position=position), parent=root_node))
            if len(action_choice.players) == len(action_choice.positions) == 0:
                root_node.children.append(Node(Action(action_choice.action_type), parent=root_node))

        print(f'actions after : {root_node.children}')

        best_node = None
        # print(f"Evaluating {len(root_node.children)} nodes")
        t = time.time()
        for node in root_node.children:
            game_copy.step(node.action)
            while not game.state.game_over and len(game.state.available_actions) == 0:
                game_copy.step()
            score = self._evaluate(game)
            node.visit(score)
            print(f"{node.action.action_type}: {node.score()}")
            if best_node is None or node.score() > best_node.score():
                best_node = node

            game_copy.revert(root_step)

        # print(f"{best_node.action.action_type} selected in {time.time() - t} seconds")
        print(f"best action : {best_node.action}")
        input()
        return best_node.action

    def _evaluate(self, game: botbowl.core.game.Game):
        print('last action', game.last_action_time)


        return random.random()

        # return (self.n_wins / self.n_simulations) + (0.1 * np.sqrt(np.log(self.parent.n_simulations) / self.n_simulations)) 

    def end_game(self, game):
        pass


# Register the bot to the framework
botbowl.register_bot('search-bot', SearchBot)

if __name__ == '__main__':
    # Load configurations, rules, arena and teams
    config = botbowl.load_config("bot-bowl")
    ruleset = botbowl.load_rule_set(config.ruleset)
    arena = botbowl.load_arena(config.arena)
    home = botbowl.load_team_by_filename("human", ruleset)
    away = botbowl.load_team_by_filename("human", ruleset)
    config.competition_mode = False
    config.debug_mode = False
    config.fast_mode = True
    config.pathfinding_enabled = False

    # Play a game
    bot_a = botbowl.make_bot("search-bot")
    bot_b = botbowl.make_bot("search-bot")
    game = botbowl.Game(1, home, away, bot_a, bot_b, config, arena=arena, ruleset=ruleset)
    print("Starting game")
    game.init()
    print("Game is over")
