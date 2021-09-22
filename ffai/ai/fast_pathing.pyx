# distutils: language=c++

import cython
cimport cython

from libcpp.queue cimport priority_queue

import ffai.core.table as table
import ffai.core.model as model

from libcpp.map cimport map as mapcpp
#from libcpp.functional.less cimport less
from cython.operator import dereference, postincrement

from libcpp.memory cimport shared_ptr

from pathing_node cimport Node, Square
ctypedef shared_ptr[Node] NodePtr

from libcpp.memory cimport shared_ptr
ctypedef shared_ptr[Node] Node_ptr

# import Path class? Because reversable

"""
cpdef object ffai_Square(Square sq):
    return model.Square(sq.x, sq.y)


cpdef Square from_ffai_Square(object sq):
    cdef Square c_square
    c_square.x = sq.x
    c_square.y = sq.y
    return c_square
"""

cdef Square DIRECTIONS[8]
DIRECTIONS[0].x = -1; DIRECTIONS[0].y = -1
DIRECTIONS[1].x = -1; DIRECTIONS[1].y = 0
DIRECTIONS[2].x = -1; DIRECTIONS[2].y = 1
DIRECTIONS[3].x = 0; DIRECTIONS[3].y = -1
DIRECTIONS[4].x = 0; DIRECTIONS[4].y = 1
DIRECTIONS[5].x = 1; DIRECTIONS[5].y = -1
DIRECTIONS[6].x = 1; DIRECTIONS[6].y = 0
DIRECTIONS[7].x = 1; DIRECTIONS[7].y = 1


cdef class Pathfinder:
    cdef object game
    cdef object player
    cdef bint trr
    cdef bint directly_to_adjacent
    cdef bint can_block
    cdef bint can_handoff
    cdef bint can_foul
    cdef int ma
    cdef int gfis
    cdef NodePtr locked_nodes[17][28] # initalized as empty pointers
    cdef NodePtr nodes[17][28] # initalized as empty pointers
    cdef int tzones[17][28]
    cdef double current_prob
    cdef priority_queue[NodePtr] open_set
    cdef map[double, NodePtr] risky_set #dict

    def __init__(self, game, player, trr=False, directly_to_adjacent=False, can_block=False, can_handoff=False, can_foul=False):
        self.game = game
        self.player = player
        self.trr = trr
        self.directly_to_adjacent = directly_to_adjacent
        self.can_block = can_block
        self.can_handoff = can_handoff
        self.can_foul = can_foul
        self.ma = player.get_ma() - player.state.moves
        # self.gfis = 3 if player.has_skill(Skill.SPRINT) else 2
        self.current_prob = 1
        
        # Doesn't need initialization? 
        self.open_set = priority_queue[Node]() # self.open_set = PriorityQueue()
        self.risky_sets = map[double, NodePtr]()  # self.risky_sets = {}
        
        for p in game.get_players_on_pitch():
            if p.team != player.team and p.has_tackle_zone():
                for square in game.get_adjacent_squares(p.position):
                    self.tzones[square.y][square.x] += 1

"""
    cdef get_path(self, target):
        paths = self.get_paths(target)
        if len(paths) > 0:
            return paths[0]
        return None

    cdef get_paths(self, target=None):
        cdef Square start_square
        cdef Node node
        ma = self.player.get_ma() - self.player.state.moves
        self.ma = max(0, ma)
        gfis_used = 0 if ma >= 0 else -ma
        self.gfis = 2-gfis_used #3-gfis_used if self.player.has_skill(Skill.SPRINT) else 2-gfis_used

        start_square.x = self.player.position.x
        start_square.y = self.player.position.y


        if self.ma + self.gfis <= 0:
            return []

        can_dodge = self.player.has_skill(table.Skill.DODGE) and table.Skill.DODGE not in self.player.state.used_skills
        can_sure_feet = self.player.has_skill(table.Skill.SURE_FEET) and table.Skill.SURE_FEET not in self.player.state.used_skills
        can_sure_hands = self.player.has_skill(table.Skill.SURE_HANDS)
        rr_states = {(self.trr, can_dodge, can_sure_feet, can_sure_hands): 1}
        node = create_root_node(&start_square, self.ma, self.gfis, euclidean_distance=0, rr_states=rr_states)
        if not self.player.state.up:
            node = self._expand_stand_up(node)
            self.nodes[node.position.y][node.position.x] = node
        self.open_set.put((0, node))
        self._expansion(target)
        self._clear()

        while len(self.risky_sets) > 0:
            self._prepare_nodes()
            self._expansion(target)
            self._clear()

        return self._collect_paths(target)

    cdef _get_pickup_target(self, to_pos):
        zones_to = self.tzones[to_pos.y][to_pos.x]
        modifiers = 1
        if not self.player.has_skill(Skill.BIG_HAND):
            modifiers -= int(zones_to)
        if self.game.state.weather == WeatherType.POURING_RAIN:
            if not self.player.has_skill(Skill.BIG_HAND):
                modifiers -= 1
        if self.player.has_skill(Skill.EXTRA_ARMS):
            modifiers += 1
        target = Rules.agility_table[self.player.get_ag()] - modifiers
        return min(6, max(2, target))

    cdef _get_handoff_target(self, catcher):
        modifiers = self.game.get_catch_modifiers(catcher, handoff=True)
        target = Rules.agility_table[catcher.get_ag()] - modifiers
        return min(6, max(2, target))

    cdef _get_dodge_target(self, from_pos, to_pos):
        zones_from = self.tzones[from_pos.y][from_pos.x]
        if zones_from == 0:
            return None
        zones_to = int(self.tzones[to_pos.y][to_pos.x])
        modifiers = 1

        ignore_opp_mods = False
        if self.player.has_skill(Skill.STUNTY):
            modifiers = 1
            ignore_opp_mods = True
        if self.player.has_skill(Skill.TITCHY):
            modifiers += 1
            ignore_opp_mods = True
        if self.player.has_skill(Skill.TWO_HEADS):
            modifiers += 1

        if not ignore_opp_mods:
            modifiers -= zones_to

        target = Rules.agility_table[self.player.get_ag()] - modifiers
        return min(6, max(2, target))

    def _expand(self, Node * node, target=None):
        
        if node.block_dice is not None or node.handoff_roll is not None:
            return

        out_of_moves = False
        if node.moves_left + node.gfis_left == 0:
            if not self.can_handoff:
                return
            out_of_moves = True

        for direction in self.DIRECTIONS:
            next_node = self._expand_node(node, direction, out_of_moves=out_of_moves)
            if next_node is None:
                continue
            rounded_p = round(next_node.prob, 6)
            if rounded_p < self.current_prob:
                self._add_risky_move(rounded_p, next_node)
            else:
                self.open_set.put((next_node.euclidean_distance, next_node))
                self.nodes[next_node.position.y][next_node.position.x] = next_node

    cdef _expand_node(self, Node * node, direction, out_of_moves=False):
        euclidean_distance = node.euclidean_distance + 1 if direction.x == 0 or direction.y == 0 else node.euclidean_distance + 1.41421
        to_pos = self.game.state.pitch.squares[node.position.y + direction.y][node.position.x + direction.x]
        if not (1 <= to_pos.x < self.game.arena.width - 1 and 1 <= to_pos.y < self.game.arena.height - 1):
            return None
        player_at = self.game.get_player_at(to_pos)
        if player_at is not None:
            if player_at.team == self.player.team and self.can_handoff and player_at.can_catch():
                return self._expand_handoff_node(node, to_pos)
            elif player_at.team != self.player.team and self.can_block and player_at.state.up:
                return self._expand_block_node(node, euclidean_distance, to_pos, player_at)
            elif player_at.team != self.player.team and self.can_foul and not player_at.state.up:
                return self._expand_foul_node(node, to_pos, player_at)
            return None
        if not out_of_moves:
            return self._expand_move_node(node, euclidean_distance, to_pos)
        return None

    def _expand_move_node(self, Node * node, euclidean_distance, to_pos):
        cdef Node* best_node = self.nodes[to_pos.y][to_pos.x]
        cdef Node* best_before = self.locked_nodes[to_pos.y][to_pos.x]
        cdef bint gfi = node.moves_left == 0
        moves_left_next = max(0, node.moves_left - 1)
        gfis_left_next = node.gfis_left - 1 if gfi else node.gfis_left
        total_moves_left = moves_left_next + gfis_left_next
        if best_node is not None:
            best_total_moves_left = best_node.moves_left + best_node.gfis_left
            if total_moves_left < best_total_moves_left:
                return None
            if total_moves_left == best_total_moves_left and euclidean_distance > best_node.euclidean_distance:
                return None
        next_node = Node(node, to_pos, moves_left_next, gfis_left_next, euclidean_distance)
        if gfi:
            next_node.apply_gfi()
        if self.tzones[node.position.y][node.position.x] > 0:
            target = self._get_dodge_target(node.position, to_pos)
            next_node.apply_dodge(target)
        if self.game.get_ball_position() == to_pos:
            target = self._get_pickup_target(to_pos)
            next_node.apply_pickup(target)
        if best_before is not None and self._dominant(next_node, best_before) == best_before:
            return None
        return next_node

    cdef _expand_foul_node(self,Node * node, to_pos, player_at):
        best_node = self.nodes[to_pos.y][to_pos.x]
        best_before = self.locked_nodes[to_pos.y][to_pos.x]
        assists_from, assists_to = self.game.num_assists_at(self.player, player_at, node.position, foul=True)
        target = min(12, max(2, player_at.get_av() + 1 - assists_from + assists_to))
        next_node = Node(node, to_pos, 0, 0, node.euclidean_distance)
        next_node.apply_foul(target)
        if best_node is not None and self._best(next_node, best_node) == best_node:
            return None
        if best_before is not None and self._dominant(next_node, best_before) == best_before:
            return None
        return next_node

    cdef _expand_handoff_node(self, Node * node, to_pos):
        best_node = self.nodes[to_pos.y][to_pos.x]
        best_before = self.locked_nodes[to_pos.y][to_pos.x]
        player_at = self.game.get_player_at(to_pos)
        next_node = Node(node, to_pos, 0, 0, node.euclidean_distance)
        target = self._get_handoff_target(player_at)
        next_node.apply_handoff(target)
        if best_node is not None and self._best(next_node, best_node) == best_node:
            return None
        if best_before is not None and self._dominant(next_node, best_before) == best_before:
            return None
        return next_node

    cdef _expand_block_node(self, Node * node, euclidean_distance, to_pos, player_at):
        best_node = self.nodes[to_pos.y][to_pos.x]
        best_before = self.locked_nodes[to_pos.y][to_pos.x]
        block_dice = self.game.num_block_dice_at(attacker=self.player, defender=player_at, position=node.position,
                                                 blitz=True)
        gfi = node.moves_left == 0
        moves_left_next = node.moves_left - 1 if not gfi else node.moves_left
        gfis_left_next = node.gfis_left - 1 if gfi else node.gfis_left
        next_node = Node(node, to_pos, moves_left_next, gfis_left_next, euclidean_distance, block_dice=block_dice)
        if gfi:
            next_node.apply_gfi()
        if best_node is not None and self._best(next_node, best_node) == best_node:
            return None
        if best_before is not None and self._dominant(next_node, best_before) == best_before:
            return None
        return next_node

    cdef _add_risky_move(self, prob, Node * node):
        if prob not in self.risky_sets:
            self.risky_sets[prob] = []
        self.risky_sets[prob].append(node)

    cdef _expand_stand_up(self, Node * node):
        if self.player.has_skill(table.Skill.JUMP_UP):
            return Node(node, self.player.position, self.ma, self.gfis, euclidean_distance=0)
        elif self.ma < 3:
            target = max(2, min(6, 4-self.game.get_stand_up_modifier(self.player)))
            next_node = Node(node, from_ffai_Square(self.player.position), 0, self.gfis, euclidean_distance=0)
            next_node.apply_stand_up(target)
            return next_node
        next_node = Node(node, self.player.position, self.ma - 3, self.gfis, euclidean_distance=0)
        return next_node

    cdef Node * _best(self, Node * a, Node *b):
        if self.directly_to_adjacent and a.position.distance(self.player.position) == 1 and a.moves_left > b.moves_left:
            return a
        if self.directly_to_adjacent and b.position.distance(self.player.position) == 1 and b.moves_left > a.moves_left:
            return b
        a_moves_left = a.moves_left + a.gfis_left
        b_moves_left = b.moves_left + b.gfis_left
        block = a.block_dice is not None
        foul = a.foul_roll is not None
        if a.prob > b.prob:
            return a
        if b.prob > a.prob:
            return b
        if foul and a.foul_roll < b.foul_roll:
            return a
        if foul and b.foul_roll < a.foul_roll:
            return b
        if block and a.block_dice > b.block_dice:
            return a
        if block and b.block_dice > a.block_dice:
            return b
        if a_moves_left > b_moves_left:
            return a
        if b_moves_left > a_moves_left:
            return b
        if a.euclidean_distance < b.euclidean_distance:
            return a
        if b.euclidean_distance < a.euclidean_distance:
            return b
        return NULL

    cdef Node * _dominant(self, Node * a, Node *b):
        if self.directly_to_adjacent and a.position.distance(self.player.position) == 1 and a.moves_left > b.moves_left:
            return a
        if self.directly_to_adjacent and b.position.distance(self.player.position) == 1 and b.moves_left > a.moves_left:
            return b
        a_moves_left = a.moves_left + a.gfis_left
        b_moves_left = b.moves_left + b.gfis_left
        # TODO: Write out as above
        if a.prob > b.prob and (a.foul_roll is None or a.foul_roll <= b.foul_roll) and (a.block_dice is None or a.block_dice >= b.block_dice) and (a_moves_left > b_moves_left or (a_moves_left == b_moves_left and a.euclidean_distance < b.euclidean_distance)):
            return a
        if b.prob > a.prob and (b.foul_roll is None or b.foul_roll <= a.foul_roll) and (b.block_dice is None or b.block_dice >= a.block_dice) and (b_moves_left > a_moves_left or (b_moves_left == a_moves_left and b.euclidean_distance < a.euclidean_distance)):
            return b
        return NULL

    cdef _clear(self):
        cdef Node* node
        cdef Node* before
        for y in range(self.game.arena.height):
            for x in range(self.game.arena.width):
                node = self.nodes[y][x]
                if node is not NULL:
                    before = self.locked_nodes[y][x]
                    if before is NULL or self._best(node, before) == node:
                        self.locked_nodes[y][x] = node
                    self.nodes[y][x] = NULL
        self.open_set = PriorityQueue()

    cdef _prepare_nodes(self):
        cdef Node* node
        cdef Node* existing_node
        cdef Node* best_before

        if len(self.risky_sets) > 0:
            probs = sorted(self.risky_sets.keys())
            self.current_prob = probs[-1]
            for node in self.risky_sets[probs[-1]]:
                best_before = self.locked_nodes[node.position.y][node.position.x]
                if best_before is not NULL and self._dominant(best_before, node) == best_before:
                    continue
                existing_node = self.nodes[node.position.y][node.position.x]
                if existing_node is NULL or self._best(existing_node, node) == node:
                    self.open_set.push((node.euclidean_distance, node))
                    self.nodes[node.position.y][node.position.x] = node
            del self.risky_sets[probs[-1]]

    cdef _expansion(self, target=None):
        cdef Node best_node
        while not self.open_set.empty():
            best_node = self.open_set.top()
            self._expand(best_node, target)

    cdef _collect_paths(self, target=None):
        cdef Node* node
        if type(target) == Square:
            node = self.locked_nodes[target.y][target.x]
            if node is not NULL:
                return [self._collect_path(node)]
            return []

        paths = []
        for y in range(self.game.arena.height):
            for x in range(self.game.arena.width):
                if self.player.position.x == x and self.player.position.y == y:
                    continue
                if type(target) == int and not target == x:
                    continue
                node = self.locked_nodes[y][x]
                if node is not NULL:
                    paths.append(self._collect_path(node))
        return paths

    cdef _collect_path(self, Node * node):
        prob = node.prob
        steps = [ ffai_Square(node.position) ]
        rolls = [node.rolls]
        block_dice = node.block_dice
        foul_roll = node.foul_roll
        handoff_roll = node.handoff_roll
        node = node.parent
        while node is not NULL:
            steps.append( ffai_Square(node.position) )
            rolls.append(node.rolls)
            node = node.parent
        steps = list(reversed(steps))[1:]
        rolls = list(reversed(rolls))[1:]
        return Path(steps, prob=prob, rolls=rolls, block_dice=block_dice, foul_roll=foul_roll, handoff_roll=handoff_roll)



#cpdef get_all_paths(...)
"""
