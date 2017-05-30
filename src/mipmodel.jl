# Given a direction, what is the preceding direction
function preceding_direction(dir::Direction)
    prec_dir = (dir - 1) % 8
    if prec_dir < 0
        7
    else
        prec_dir
    end
end
macro check_pairs(vals, a, b, c, d)
:(($vals[$a] - $vals[$c] <= -d_min &&
    $vals[$a] - $vals[$d] <= -d_min &&
    $vals[$b] - $vals[$c] <= -d_min &&
    $vals[$b] - $vals[$d] <= -d_min))
end

function build_model!(model, transit_map::InputGraph, planarity_constraints = true)

    # model parameters
    station_list = stations(transit_map)
    edge_list = edges(transit_map)
    N = nstations(transit_map)
    M = nedges(transit_map)
    d_min = 1
    # max canvas should be as small as possible for bigM formulation
    max_canvas = sum(map(x -> x.min_length, edge_list))
    get_degree = x -> out_degree(transit_map, x)
    max_degree = maximum(map(get_degree, station_list))

    # now we need a mapping from a station id to a number from 1:N
    # the same is needed is needed for edges
    # Todo: Make this run in constant time
    # TODO: Also redo all those helper functions
    function get_station_index(station_id)
        p = 1
        for i in 1:N
            if station_list[i].id == station_id
                return p
            end
            p = p + 1
        end
        -1
    end

    function get_edge_index(edge_id)
        p = 1
        for i in 1:M
            if edge_list[i].id == edge_id
                return p
            end
            p = p + 1
        end
        -1
    end

    function get_neighbors(station)
        # try only the out-degree
        neighbors_from = map(x -> x.to.id, filter(x -> x.from == station && !x.is_single_label_edge, edge_list))
        #neighbors_to = map(x -> x.from.id, filter(x -> x.to == station, edge_list))
        #setdiff(unique(vcat(neighbors_from, neighbors_to)), [station.id])
        setdiff(unique(neighbors_from), [station.id])
    end

    # TODO: Is this really correct?
    function sort_node_by_direction(root_node)
        function (target_node)
            t1 = map(x -> x.direction, filter(x -> x.from.id == root_node && x.to.id == target_node, edge_list))
            #t2 = map(x -> x.direction, filter(x -> x.from.id == target_node && x.to.id == root_node, edge_list))
            #println(root_node, target_node, t1, ";", t2)
            #if length(t2) > 0
            #    (first(t2) + 4) % 8
            #elseif length(t1) > 0
            first(t1)
            #else
            #    # should not happen
            #    error("Could not find edge from ", root_node, "->", target_node, ".")
            #end
        end
    end

    # We need a list of incident edges for the bend costs
    indicent_edge_list = incident_edges(transit_map)
    n_incident_edges = length(indicent_edge_list)

    # also for the planarity constraints we need a list of
    # non_incident_edges edges
    non_indicent_edge_list = non_incident_edges(transit_map)
    n_non_incident_edges = length(non_indicent_edge_list)

    # TODO: Only edge variables for non dummy edges / nodes
    # where sensible
    # setup variables
    @variable(model, 0 <= x[1:N] <= max_canvas)
    @variable(model, 0 <= y[1:N] <= max_canvas)
    @variable(model, 0 <= z1[1:N] <= max_canvas)
    @variable(model, 0 <= z2[1:N] <= max_canvas)
    @variable(model, 1 <= elen[1:M] <= max_canvas)
    @variable(model, 0 <= a[1:M, 1:3] <= 1, Bin)

    # the direction variables
    # only add those that are really needed
    function is_edge(i, j)
        u = station_list[i]
        v = station_list[j]
        length(filter(x -> x.from == u && x.to == v || x.to == u && x.from == v, edge_list)) > 0
    end
    @variable(model, 0 <= d[i = 1:N, j = 1:N; is_edge(i, j)] <= 7)

    @variable(model, 0 <= b[1:N, 1:max_degree] <= 1, Bin)

    # bend cost
    @variable(model, 0 <= bc[1:n_incident_edges] <= 1, Bin)
    @variable(model, 0 <= bc_s1[1:n_incident_edges] <= 1, Bin)
    @variable(model, 0 <= bc_s2[1:n_incident_edges] <= 1, Bin)

    # relative postions
    @variable(model, 0 <= rpos[1:M] <= 1, Bin)

    # planarity
    if planarity_constraints
        @variable(model, 0 <= g[1:n_non_incident_edges, 0:7] <= 1, Bin)
    end

    # The objective is a weighted sum that needs to be minimized
    @objective(model, Min, 3 * sum(elen[i] for i = 1:M) +
                      3 * sum(bc[i] for i = 1:n_incident_edges) +
                      1 * sum(rpos[i] for i = 1:M))

    # first some general constraints to model the relationship with
    # xy and z variables
    # For each node
    for i in 1:N
        @constraint(model, z1[i] == x[i] + y[i])
        @constraint(model, z2[i] == x[i] - y[i])
    end
    # For each edge
    for i in 1:M

        # We need to ensure that only one sector is chosen per edge
        @constraint(model, sum(a[i, s] for s = 1:3) == 1)

        edge = edge_list[i]
        min_length = edge.min_length
        orig_dir = edge.direction
        u = get_station_index(edge.from.id)
        v = get_station_index(edge.to.id)
        is_single_label_edge = edge.is_single_label_edge
        is_standard_edge = !is_single_label_edge

        # Ensure that the direction variable has the correct value
        # This block also defines the d variables
        # as I did not figure out how to create a selective group of variables
        prec_dir = preceding_direction(orig_dir)
        succ_dir = (orig_dir + 1) % 8
        orig_dir_rev = (orig_dir + 4) % 8
        prec_dir_rev = preceding_direction(orig_dir_rev)
        succ_dir_rev = (orig_dir_rev + 1) % 8
        dir = [prec_dir, orig_dir, succ_dir]
        dir_rev = [prec_dir_rev, orig_dir_rev, succ_dir_rev]
        if is_standard_edge
            @constraint(model, d[u, v] == prec_dir * a[i, 1] +
                orig_dir * a[i, 2] + succ_dir * a[i, 3])
            @constraint(model, d[v, u] == prec_dir_rev * a[i, 1] +
                orig_dir_rev * a[i, 2] + succ_dir_rev * a[i, 3])
        end

        # constraints that ensure that the relative position cost are
        # computed correctly
        if is_standard_edge
            @constraint(model, -8 * rpos[i] <= d[u, v] - orig_dir)
            @constraint(model, 8 * rpos[i] >= d[u, v] - orig_dir)
        end
        # now we need to set the edge length variable
        # elen is an upperbound on the edgelength
        @constraint(model, x[u] - x[v] <= elen[i])
        @constraint(model, -x[u] + x[v] <= elen[i])
        @constraint(model, y[u] - y[v] <= elen[i])
        @constraint(model, -y[u] + y[v] <= elen[i])

        # the following block ensures the octoliniarity
        if is_standard_edge
            for s in 1:3
                @constraint(model, d[u, v] - dir[s] <= 7 * (1 - a[i, s]))
                @constraint(model, d[u, v] - dir[s] >= -7 * (1 - a[i, s]))
                @constraint(model, d[v, u] - dir_rev[s] <= 7 * (1 - a[i, s]))
                @constraint(model, d[v, u] - dir_rev[s] >= -7 * (1 - a[i, s]))
            end
        end

        # For dummy edges for single labels only selected directions are possible
        # direction 2 and 6 are not possible
        if is_single_label_edge
            allowed_dirs = [1, 3, 4, 5, 7]
            ae = @variable(model, [i, allowed_dirs], Bin)
            @constraint(model, sum(ae[i, d] for d = allowed_dirs) <= 1)
            # Do I need to set the reverse edge?
            @constraint(model, d[u, v] == sum(d * ae[i, d] for d = allowed_dirs))
        end

        bM = max_canvas

        # Todo: Extract this into a macro
        if orig_dir == 0
            # direction == 7
            @constraint(model, z1[v] - z1[u] <= bM * (1 - a[i, 1]))
            @constraint(model, z1[v] - z1[u] >= -1 * bM * (1 - a[i, 1]))
            @constraint(model, z2[v] - z2[u] >= -(bM + min_length) * (1 - a[i, 1]) + 2 * min_length)

            # direction == 0
            @constraint(model, y[v] - y[u] <= bM * (1 - a[i, 2]))
            @constraint(model, y[v] - y[u] >= -bM * (1 - a[i, 2]))
            @constraint(model, x[v] - x[u] >= -1 * (bM + min_length) * (1 - a[i, 2]) + min_length)

            # direction == 1
            @constraint(model, z2[v] - z2[u] <= bM * (1 - a[i, 3]))
            @constraint(model, z2[v] - z2[u] >= -1 * bM * (1 - a[i, 3]))
            @constraint(model, z1[v] - z1[u] >= -1 * (bM + min_length) * (1 - a[i, 3]) + 2 * min_length)
        elseif orig_dir == 1
            # direction == 0
            @constraint(model, y[v] - y[u] <= bM * (1 - a[i, 1]))
            @constraint(model, y[v] - y[u] >= -bM * (1 - a[i, 1]))
            @constraint(model, x[v] - x[u] >= -(bM + min_length) * (1 - a[i, 1]) + min_length)

            # direction == 1
            @constraint(model, z2[v] - z2[u] <= 1 * bM * (1 - a[i, 2]))
            @constraint(model, z2[v] - z2[u] >= -1 * bM * (1 - a[i, 2]))
            @constraint(model, z1[v] - z1[u] >= -1 * (bM + min_length) * (1 - a[i, 2]) + 2 * min_length)

            # direction == 2
            @constraint(model, x[v] - x[u] <= bM * (1 - a[i, 3]))
            @constraint(model, x[v] - x[u] >= -bM * (1 - a[i, 3]))
            @constraint(model, y[v] - y[u] >= -(bM + min_length) * (1 - a[i, 3]) + min_length)
        elseif orig_dir == 2
            # direction == 1
            @constraint(model, z2[v] - z2[u] <= 1 * bM * (1 - a[i, 1]))
            @constraint(model, z2[v] - z2[u] >= -1 * bM * (1 - a[i, 1]))
            @constraint(model, z1[v] - z1[u] >= -1 * (bM + min_length) * (1 - a[i, 1]) + 2 * min_length)

            # direction == 2
            @constraint(model, x[u] - x[v] <= bM * (1 - a[i, 2]))
            @constraint(model, x[u] - x[v] >= -bM * (1 - a[i, 2]))
            @constraint(model, y[v] - y[u] >= -(bM + min_length) * (1 - a[i, 2]) + min_length)

            # direction == 3
            @constraint(model, z1[u] - z1[v] <= 1 * bM * (1 - a[i, 3]))
            @constraint(model, z1[u] - z1[v] >= -1 * bM * (1 - a[i, 3]))
            @constraint(model, z2[u] - z2[v] >= -1 * (bM + min_length) * (1 - a[i, 3]) + 2 * min_length)
        elseif orig_dir == 3
            # direction == 2
            @constraint(model, x[u] - x[v] <= bM * (1 - a[i, 1]))
            @constraint(model, x[u] - x[v] >= -bM * (1 - a[i, 1]))
            @constraint(model, y[v] - y[u] >= -(bM + min_length) * (1 - a[i, 1]) + min_length)

            # direction == 3
            @constraint(model, z1[u] - z1[v] <= 1 * bM * (1 - a[i, 2]))
            @constraint(model, z1[u] - z1[v] >= -1 * bM * (1 - a[i, 2]))
            @constraint(model, z2[u] - z2[v] >= -1 * (bM + min_length) * (1 - a[i, 2]) + 2 * min_length)

            # direction == 4
            @constraint(model, y[u] - y[v] <= bM * (1 - a[i, 3]))
            @constraint(model, y[u] - y[v] >= -bM * (1 - a[i, 3]))
            @constraint(model, x[u] - x[v] >= -(bM + min_length) * (1 - a[i, 3]) + min_length)
        elseif orig_dir == 4
            # direction == 3
            @constraint(model, z1[u] - z1[v] <= 1 * bM * (1 - a[i, 1]))
            @constraint(model, z1[u] - z1[v] >= -1 * bM * (1 - a[i, 1]))
            @constraint(model, z2[u] - z2[v] >= -1 * (bM + min_length) * (1 - a[i, 1]) + 2 * min_length)

            # direction == 4
            @constraint(model, y[u] - y[v] <= bM * (1 - a[i, 2]))
            @constraint(model, y[u] - y[v] >= -bM * (1 - a[i, 2]))
            @constraint(model, x[u] - x[v] >= -(bM + min_length) * (1 - a[i, 2]) + min_length)

            # direction == 5
            @constraint(model, z2[u] - z2[v] <= 1 * bM * (1 - a[i, 3]))
            @constraint(model, z2[u] - z2[v] >= -1 * bM * (1 - a[i, 3]))
            @constraint(model, z1[u] - z1[v] >= -1 * (bM + min_length) * (1 - a[i, 3]) + 2 * min_length)
        elseif orig_dir == 5

            # direction == 4
            @constraint(model, y[u] - y[v] <= bM * (1 - a[i, 1]))
            @constraint(model, y[u] - y[v] >= -bM * (1 - a[i, 1]))
            @constraint(model, x[u] - x[v] >= -(bM + min_length) * (1 - a[i, 1]) + min_length)

            # direction == 5
            @constraint(model, z2[u] - z2[v] <= 1 * bM * (1 - a[i, 2]))
            @constraint(model, z2[u] - z2[v] >= -1 * bM * (1 - a[i, 2]))
            @constraint(model, z1[u] - z1[v] >= -1 * (bM + min_length) * (1 - a[i, 2]) + 2 * min_length)

            # direction == 6
            @constraint(model, x[u] - x[v] <= bM * (1 - a[i, 3]))
            @constraint(model, x[u] - x[v] >= -bM * (1 - a[i, 3]))
            @constraint(model, y[u] - y[v] >= -(bM + min_length) * (1 - a[i, 3]) + min_length)
        elseif orig_dir == 6
            # direction == 5
            @constraint(model, z2[u] - z2[v] <= 1 * bM * (1 - a[i, 1]))
            @constraint(model, z2[u] - z2[v] >= -1 * bM * (1 - a[i, 1]))
            @constraint(model, z1[u] - z1[v] >= -1 * (bM + min_length) * (1 - a[i, 1]) + 2 * min_length)

            # direction == 6
            @constraint(model, x[u] - x[v] <= bM * (1 - a[i, 2]))
            @constraint(model, x[u] - x[v] >= -bM * (1 - a[i, 2]))
            @constraint(model, y[u] - y[v] >= -(bM + min_length) * (1 - a[i, 2]) + min_length)

            # direction == 7
            @constraint(model, z1[u] - z1[v] <= 1 * bM * (1 - a[i, 3]))
            @constraint(model, z1[u] - z1[v] >= -1 * bM * (1 - a[i, 3]))
            @constraint(model, z2[v] - z2[u] >= -1 * (bM + min_length) * (1 - a[i, 3]) + 2 * min_length)
        elseif orig_dir == 7
            # direction == 6
            @constraint(model, x[u] - x[v] <= bM * (1 - a[i, 1]))
            @constraint(model, x[u] - x[v] >= -bM * (1 - a[i, 1]))
            @constraint(model, y[u] - y[v] >= -(bM + min_length) * (1 - a[i, 1]) + min_length)

            # direction == 7
            @constraint(model, z1[u] - z1[v] <= 1 * bM * (1 - a[i, 2]))
            @constraint(model, z1[u] - z1[v] >= -1 * bM * (1 - a[i, 2]))
            @constraint(model, z2[v] - z2[u] >= -1 * (bM + min_length) * (1 - a[i, 2]) + 2 * min_length)

            # direction == 0
            @constraint(model, y[u] - y[v] <= bM * (1 - a[i, 3]))
            @constraint(model, y[u] - y[v] >= -bM * (1 - a[i, 3]))
            @constraint(model, x[v] - x[u] >= -(bM + min_length) * (1 - a[i, 3]) + min_length)
        else
            error("Direction not between 0 and 7")
        end
    end

    for i in 1:N
        #continue
        # we also need to add the circular order constraints
        station = station_list[i]
        station_id = station.id
        deg = out_degree(transit_map, station)
        neighbors = get_neighbors(station)
        if deg >= 2 && length(neighbors) >= 2
            #println(i, sort(neighbors, by = sort_node_by_direction(station_id)))
            neighbor_indexes = map(get_station_index,
                                    sort(neighbors, by = sort_node_by_direction(station_id)))
            @constraint(model, sum(b[i, j] for j = 1:length(neighbors)) == 1)

            # add circle constraints
            for j in 1:length(neighbor_indexes)
                jIdx = neighbor_indexes[j]
                if j + 1 <= length(neighbor_indexes)
                    jIdxP = neighbor_indexes[j + 1]
                else
                    jIdxP = neighbor_indexes[1]
                end
                @constraint(model, d[i, jIdx] <= d[i, jIdxP] - 1 + 8*b[i, j])
            end
        end
    end

    if planarity_constraints
        # last step is to register a callback to preserve planarity
        function check_edge_spacing(cb)
            bM2 = max_canvas + d_min
            x_val = getvalue(x)
            y_val = getvalue(y)
            z1_val = getvalue(z1)
            z2_val = getvalue(z2)
            #println("Enter callback")
            for i in 1:n_non_incident_edges
                t = non_indicent_edge_list[i]
                e1 = t[1]
                e2 = t[2]
                u1 = get_station_index(e1.from.id)
                v1 = get_station_index(e1.to.id)
                u2 = get_station_index(e2.from.id)
                v2 = get_station_index(e2.to.id)
                if !(@check_pairs(x_val, u1, v1, u2, v2) ||
                    @check_pairs(z1_val, u1, v1, u2, v2) ||
                    @check_pairs(y_val, u1, v1, u2, v2) ||
                    @check_pairs(z2_val, u1, v1, u2, v2) ||

                    @check_pairs(z2_val, u2, v2, u1, v1) ||
                    @check_pairs(x_val, u2, v2, u1, v1) ||
                    @check_pairs(z1_val, u2, v2, u1, v1) ||
                    @check_pairs(y_val, u2, v2, u1, v1))
                    # now we need to add a constraint that prevents this
                    #println("Adding constraint for tuple ", t)
                    #println(getvalue(g[i, 0:7]))
                    #if sum(getvalue(g[i, 0:7])) > 0
                    #    println("e1: ", getvalue(x[u1]), "/", getvalue(y[u1]), "->", getvalue(x[v1]), "/", getvalue(y[v1]))
                    #    println("e2: ", getvalue(x[u2]), "/", getvalue(y[u2]), "->", getvalue(x[v2]), "/", getvalue(y[v2]))
                    #    println(getvalue(x[u1]) - getvalue(x[u2]), "<=", bM2 * (1 - getvalue(g[i, 0])) -d_min)
                    #    println(getvalue(x[u1]) - getvalue(x[v2]), "<=", bM2 * (1 - getvalue(g[i, 0])) -d_min)
                    #    println(getvalue(x[v1]) - getvalue(x[u2]), "<=", bM2 * (1 - getvalue(g[i, 0])) -d_min)
                    #    println(getvalue(x[v1]) - getvalue(x[v2]), "<=", bM2 * (1 - getvalue(g[i, 0])) -d_min)
                    #end
                    #printl("")
                    # TODO: mehrfach add
                    @lazyconstraint(cb, sum(g[i, d] for d = 0:7) >= 1)

                    # direction 0
                    @lazyconstraint(cb, x[u1] - x[u2] <= bM2 * (1 - g[i, 0]) - d_min)
                    @lazyconstraint(cb, x[u1] - x[v2] <= bM2 * (1 - g[i, 0]) - d_min)
                    @lazyconstraint(cb, x[v1] - x[u2] <= bM2 * (1 - g[i, 0]) - d_min)
                    @lazyconstraint(cb, x[v1] - x[v2] <= bM2 * (1 - g[i, 0]) - d_min)

                    # direction 1
                    @lazyconstraint(cb, z1[u1] - z1[u2] <= bM2 * (1 - g[i, 1]) - d_min)
                    @lazyconstraint(cb, z1[u1] - z1[v2] <= bM2 * (1 - g[i, 1]) - d_min)
                    @lazyconstraint(cb, z1[v1] - z1[u2] <= bM2 * (1 - g[i, 1]) - d_min)
                    @lazyconstraint(cb, z1[v1] - z1[v2] <= bM2 * (1 - g[i, 1]) - d_min)

                    # direction 2
                    @lazyconstraint(cb, y[u1] - y[u2] <= bM2 * (1 - g[i, 2]) - d_min)
                    @lazyconstraint(cb, y[u1] - y[v2] <= bM2 * (1 - g[i, 2]) - d_min)
                    @lazyconstraint(cb, y[v1] - y[u2] <= bM2 * (1 - g[i, 2]) - d_min)
                    @lazyconstraint(cb, y[v1] - y[v2] <= bM2 * (1 - g[i, 2]) - d_min)

                    # direction 3
                    @lazyconstraint(cb, z2[u2] - z2[u1] <= bM2 * (1 - g[i, 3]) - d_min)
                    @lazyconstraint(cb, z2[u2] - z2[v1] <= bM2 * (1 - g[i, 3]) - d_min)
                    @lazyconstraint(cb, z2[v2] - z2[u1] <= bM2 * (1 - g[i, 3]) - d_min)
                    @lazyconstraint(cb, z2[v2] - z2[v1] <= bM2 * (1 - g[i, 3]) - d_min)

                    # direction 4
                    @lazyconstraint(cb, x[u2] - x[u1] <= bM2 * (1 - g[i, 4]) - d_min)
                    @lazyconstraint(cb, x[u2] - x[v1] <= bM2 * (1 - g[i, 4]) - d_min)
                    @lazyconstraint(cb, x[v2] - x[u1] <= bM2 * (1 - g[i, 4]) - d_min)
                    @lazyconstraint(cb, x[v2] - x[v1] <= bM2 * (1 - g[i, 4]) - d_min)

                    # direction 5
                    @lazyconstraint(cb, z1[u2] - z1[u1] <= bM2 * (1 - g[i, 5]) - d_min)
                    @lazyconstraint(cb, z1[u2] - z1[v1] <= bM2 * (1 - g[i, 5]) - d_min)
                    @lazyconstraint(cb, z1[v2] - z1[u1] <= bM2 * (1 - g[i, 5]) - d_min)
                    @lazyconstraint(cb, z1[v2] - z1[v1] <= bM2 * (1 - g[i, 5]) - d_min)

                    # direction 6
                    @lazyconstraint(cb, y[u2] - y[u1] <= bM2 * (1 - g[i, 6]) - d_min)
                    @lazyconstraint(cb, y[u2] - y[v1] <= bM2 * (1 - g[i, 6]) - d_min)
                    @lazyconstraint(cb, y[v2] - y[u1] <= bM2 * (1 - g[i, 6]) - d_min)
                    @lazyconstraint(cb, y[v2] - y[v1] <= bM2 * (1 - g[i, 6]) - d_min)

                    # direction 7
                    @lazyconstraint(cb, z2[u1] - z2[u2] <= bM2 * (1 - g[i, 7]) - d_min)
                    @lazyconstraint(cb, z2[u1] - z2[v2] <= bM2 * (1 - g[i, 7]) - d_min)
                    @lazyconstraint(cb, z2[v1] - z2[u2] <= bM2 * (1 - g[i, 7]) - d_min)
                    @lazyconstraint(cb, z2[v1] - z2[v2] <= bM2 * (1 - g[i, 7]) - d_min)

                end
            end
        end
        addlazycallback(model, check_edge_spacing)
    end

    # bend cost constraints
    for i in 1:n_incident_edges
        t = indicent_edge_list[i]
        e1 = t[1]
        e2 = t[2]
        u = get_station_index(e1.from.id)
        v = get_station_index(e1.to.id)
        w = get_station_index(e2.to.id)
        @constraint(model, -1 * bc[i] <= d[u, v] - d[v, w] - 8 * bc_s1[i] + 8 * bc_s2[i])
        @constraint(model, bc[i] >= d[u, v] - d[v, w] - 8 * bc_s1[i] + 8 * bc_s2[i])
    end

    ModelVariables(x, y)
end
