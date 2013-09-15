#
# platin tool set
#
# "Inhouse" Worst-Case Execution Time Analysis using IPET
#
require 'core/utils'
require 'core/pml'
require 'analysis/ipet'
require 'analysis/cache_region_analysis'
require 'analysis/vcfg'
require 'ext/lpsolve'

module PML

class WCA

  def initialize(pml, options)
    @pml, @options = pml, options
  end

  def analyze(entry_label)

    # Builder and Analysis Entry
    ilp = LpSolveILP.new(@options)

    machine_entry = @pml.machine_functions.by_label(entry_label)
    bitcode_entry = @pml.bitcode_functions.by_name(entry_label)
    entry = { 'machinecode' => machine_entry, 'bitcode' => bitcode_entry }


    # PLAYING: VCFGs
    #bcffs,mcffs = ['bitcode','machinecode'].map { |level|
    #  @pml.flowfacts.filter(@pml,@options.flow_fact_selection,@options.flow_fact_srcs,level)
    #}
    #ctxm = ContextManager.new(@options.callstring_length,1,1,2)
    #mc_model = ControlFlowModel.new(@pml.machine_functions, machine_entry, mcffs, ctxm, @pml.arch)
    #mc_model.build_ipet(ilp) do |edge|
      # pseudo cost (1 cycle per instruction)
    #  if (edge.kind_of?(Block))
    #    edge.instructions.length
    #  else
    #    edge.source.instructions.length
    #  end
    #end

    #cfbc = ControlFlowModel.new(@pml.bitcode_functions, bitcode_entry, bcffs,
    #                            ContextManager.new(@options.callstring_length), GenericArchitecture.new)

    # BEGIN: remove me soon
    # builder
    builder = IPETBuilder.new(@pml, @options, ilp)

    # flow facts
    flowfacts = @pml.flowfacts.filter(@pml,
                                     @options.flow_fact_selection,
                                     @options.flow_fact_srcs,
                                     ["machinecode"],
                                     true)
    ff_levels = ["machinecode"]

    # Build IPET using costs from @pml.arch
    builder.build(entry, flowfacts) do |edge|
      # get list of executed instructions
      ilist =
        if (edge.kind_of?(Block))
          edge.instructions
        else
          src = edge.source
          branch_index = nil
          src.instructions.each_with_index { |ins,ix|
            if ins.returns? && edge.target == :exit
              branch_index = ix # last instruction that returns
            elsif ! ins.branch_targets.empty? && ins.branch_targets.include?(edge.target)
              branch_index = ix # last instruction that branches to the target
            end
          }
          if ! branch_index || (src.fallthrough_successor == edge.target)
            src.instructions
          else
            src.instructions[0..(branch_index+src.instructions[branch_index].delay_slots)]
          end
        end
      @pml.arch.path_wcet(src.instructions)
    end

    # run cache analyses
    CacheAnalysis.new(builder.refinement['machinecode'], @pml, @options).analyze(entry['machinecode'], builder)

    # END: remove me soon

    statistics("WCA",
               "flowfacts" => flowfacts.length,
               "ipet variables" => builder.ilp.num_variables,
               "ipet constraints" => builder.ilp.constraints.length) if @options.stats

    # Solve ILP
    begin
      cycles, freqs = builder.ilp.solve_max
    rescue Exception => ex
      warn("WCA: ILP failed: #{ex}") unless @options.disable_ipet_diagnosis
      cycles,freqs = -1, {}
    end

    # report result
    profile = Profile.new([])
    report = TimingEntry.new(machine_entry, cycles, profile,
                             'level' => 'machinecode', 'origin' => @options.timing_output || 'platin')
    # collect edge timings (TODO: add cache timings)
    edgefreq, edgecost = {}, Hash.new(0)
    freqs.each { |v,freq|
      edgecost = builder.ilp.get_cost(v)
      freq = freq.to_i
      if edgecost > 0 || (v.kind_of?(IPETEdge) && v.cfg_edge?)

        next if v.kind_of?(SubFunction)         # MC cost
        next if v.kind_of?(Instruction)         # Stack-Cache Cost
        next if v.kind_of?(InstructionCacheTag) # IC Tag
        next if v.kind_of?(DataCacheTag)        # IC Tag

        die("ILP cost: not an IPET edge") unless v.kind_of?(IPETEdge)
        die("ILP cost: source is not a block") unless v.source.kind_of?(Block)
        die("ILP cost: target is not a block") unless v.target == :exit || v.target.kind_of?(Block)
        ref = ContextRef.new(v.cfg_edge, Context.empty)
        profile.add(ProfileEntry.new(ref, edgecost, freq, edgecost*freq))
      end
    }
    if @options.verbose
      puts "Cycles: #{cycles}"
      puts "Edge Profile:"
      freqs.map { |v,freq|
        [v,freq * builder.ilp.get_cost(v)]
      }.sort_by { |v,freq|
        [v.function || machine_entry, -freq]
      }.each { |v,cost|
        puts "  #{v}: #{freqs[v]} (#{cost} cyc)"
      }
    end
    report
  end
end

end # module PML
