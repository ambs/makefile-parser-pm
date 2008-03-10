package Makefile::AST::Evaluator;

use strict;
use warnings;

#use Smart::Comments;
#use Smart::Comments '####';
use File::stat;
use Class::Trigger qw(firing_rule);

# XXX put these globals to some better place
our (
    $Quiet, $JustPrint, $IgnoreErrors,
    $AlwaysMake, $Question);

sub new ($$) {
    my $class = ref $_[0] ? ref shift : shift;
    my $ast = shift;
    return bless {
        ast     => $ast,
        updated => {},
        mtime_cache => {},  # this is better for the AST?
        parent_target => undef,
        targets_making => {},
        required_targets => {},
    }, $class;
}

sub ast ($) { $_[0]->{ast} }

sub mark_as_updated ($$) {
    my ($self, $target) = @_;
    ### marking target as updated: $target
    $self->{updated}->{$target} = 1;
}

# XXX this should be moved to the AST
sub is_updated ($$) {
    my ($self, $target) = @_;
    $self->{updated}->{$target};
}

# update the mtime cache with -M $file
sub update_mtime ($$@) {
    my ($self, $file, $cache) = @_;
    $cache ||= $self->{mtime_cache};
    if (-e $file) {
        my $stat = stat $file or
            die "$::MAKE: *** stat failed on $file: $!\n";
        ### set mtime for file: $file
        ### mtime: $stat->mtime
        return ($cache->{$file} = $stat->mtime);
    } else {
        ## file not found: $file
        return ($cache->{$file} = undef);
    }
}

# get -M $file from cache (if any) or set the cache
#  key-value pair otherwise
sub get_mtime ($$) {
    my ($self, $file) = @_;
    my $cache = $self->{mtime_cache};
    if (!exists $cache->{$file}) {
        # set the cache
        return $self->update_mtime($file, $cache);
    }
    return $cache->{$file};
}

sub set_required_target ($$) {
    my ($self, $target) = @_;
    $self->{required_targets}->{$target} = 1;
}

sub is_required_target ($$) {
    my ($self, $target) = @_;
    $self->{required_targets}->{$target};
}

sub make ($$) {
    my ($self, $target) = @_;
    return 'UP_TO_DATE'
        if $self->is_updated($target);
    my $making = $self->{targets_making};
    if ($making->{$target}) {
        warn "$::MAKE: Circular $target <- $target ".
            "dependency dropped.\n";
        return 'UP_TO_DATE';
    } else {
        $making->{$target} = 1;
    }
    my $retval;
    my @rules = $self->ast->apply_explicit_rules($target);
    ### number of explicit rules: scalar(@rules)
    if (@rules == 0) {
        ### no rule matched the target: $target
        ### trying to make implicitly here...
        my $ret = $self->make_implicitly($target);
        delete $making->{$target};
        if (!$ret) {
            return $self->make_by_rule($target => undef);
        } else {
            return $ret;
        }
    }
    # run the double-colon rules serially or run the
    # single matched single-colon rule:
    for my $rule (@rules) {
        my $ret;
        ### explicit rule for: $target
        ### explicit rule: $rule->as_str
        if (!$rule->has_command) { # XXX is this really necessary?
            ### The explicit rule has no command, so
            ### trying to make implicitly...
            $ret = $self->make_implicitly($target);
            $retval = $ret if !$retval || $ret eq 'REBUILT';
        }
        $ret = $self->make_by_rule($target => $rule);
        ### make_by_rule returned: $ret
        $retval = $ret if !$retval || $ret eq 'REBUILT';
    }
    delete $making->{$target};

    # postpone the timestamp propagation until all individual
    # rules have been updated:
    $self->update_mtime($target);

    $self->mark_as_updated($target);

    return $retval;
}

sub make_implicitly ($$) {
    my ($self, $target) = @_;
    if ($self->ast->is_phony_target($target)) {
        ### make_implicitly skipped target since it's phony: $target
        return undef;
    }
    my $rule = $self->ast->apply_implicit_rules($target);
    if (!$rule) {
        return undef;
    }
    ### implicit rule: $rule->as_str
    my $retval = $self->make_by_rule($target => $rule);
    if ($retval eq 'REBUILT') {
        for my $target ($rule->other_targets) {
            $self->mark_as_updated($target);
        }
    }
    return $retval;
}

sub make_by_rule ($$$) {
    my ($self, $target, $rule) = @_;
    ### make_by_rule (target): $target
    return 'UP_TO_DATE'
        if $self->is_updated($target) and $rule->colon eq ':';
    # XXX the parent should be passed via arguments or local vars
    my $parent = $self->{parent_target};
    ## Retrieving parent target: $parent
    if (!$rule) {
        ## HERE!
        ## exists? : -f $target
        if (-f $target) {
            return 'UP_TO_DATE';
        } else {
            if ($self->is_required_target($target)) {
                my $msg =
                    "$::MAKE: *** No rule to make target `$target'";
                if (defined $parent) {
                    $msg .=
                        ", needed by `$parent'";
                }
                print STDERR "$msg.";
                if ($Makefile::AST::Runtime) {
                    die "  Stop.\n";
                } else {
                    warn "  Ignored.\n";
                    $self->mark_as_updated($target);
                    return 'UP_TO_DATE';
                }
            } else {
                return 'UP_TO_DATE';
            }
        }
    }
    ### make_by_rule (rule): $rule->as_str
    ### stem: $rule->stem

    # XXX solve pattern-specific variables here...

    # enter pads for target-specific variables:
    # XXX in order to solve '+=' and '?=',
    # XXX we actually should NOT call enter pad
    # XXX directly here...
    my $saved_stack_len = $self->ast->pad_stack_len;
    $self->ast->enter_pad($rule->target);
    ## pad stack: $self->ast->{pad_stack}->[0]

    my $target_mtime = $self->get_mtime($target);
    my $out_of_date =
        $self->ast->is_phony_target($target) ||
        !defined $target_mtime;
    my $prereq_rebuilt;
    ## Setting parent target to: $target
    $self->{parent_target} = $target;
    # process normal prereqs:
    for my $prereq (@{ $rule->normal_prereqs }) {
        # XXX handle order-only prepreqs here
        ### processing prereq: $prereq
        $self->set_required_target($prereq);
        my $res = $self->make($prereq);
        ### make returned: $res
        if ($res and $res eq 'REBUILT') {
            $out_of_date++;
            $prereq_rebuilt++;
        } elsif ($res and $res eq 'UP_TO_DATE') {
            if (!$out_of_date) {
                if ($self->get_mtime($prereq) > $target_mtime) {
                    ### prereq file is newer: $prereq
                    $out_of_date = 1;
                }
            }
        } else {
            die "make_by_rule: Unexpected returned value for prereq $prereq: $res";
        }
    }
    # process order-only prepreqs:
    for my $prereq (@{ $rule->order_prereqs }) {
        ## process order-only prereq: $prereq
        $self->set_required_target($prereq);
        $self->make($prereq);
    }
    $self->{parent_target} = undef;
    if ($AlwaysMake || $out_of_date) {
        my @ast_cmds = $rule->prepare_commands($self->ast);
        $self->call_trigger('firing_rule', $rule, \@ast_cmds);
        if (!$Question) {
            ### firing rule's commands: $rule->as_str
            $rule->run_commands(@ast_cmds);
        }
        $self->mark_as_updated($rule->target)
            if $rule->colon eq ':';
        if (my $others = $rule->other_targets) {
            # mark "other targets" as updated too:
            for my $other (@$others) {
                ### marking "other target" as updated: $other
                $self->mark_as_updated($other);
            }
        }
        $self->ast->leave_pad(
            $self->ast->pad_stack_len - $saved_stack_len
        );
        #### AST Commands: @ast_cmds
        return 'REBUILT'
            if @ast_cmds or $prereq_rebuilt;
    }
    $self->ast->leave_pad(
        $self->ast->pad_stack_len - $saved_stack_len
    );
    return 'UP_TO_DATE';
}

1;
__END__

=head1 NAME

Makefile::AST::Evaluator - Evaluator and runtime for Makefile::AST instances

=head1 SYNOPSIS

    use Makefile::AST::Evaluator;

    $Makefile::AST::Evaluator::JustPrint = 0;
    $Makefile::AST::Evaluator::Quiet = 1;
    $Makefile::AST::Evaluator::IgnoreErrors = 1;
    $Makefile::AST::Evaluator::AlwaysMake = 1;
    $Makefile::AST::Evaluator::Question = 1;

    # $ast is a Makefile::AST instance:
    my $eval = Makefile::AST::Evaluator->new($ast);

    Makefile::AST::Evaluator->add_trigger(
        firing_rule => sub {
            my ($self, $rule, $ast_cmds) = @_;
            my $target = $rule->target;
            my $colon = $rule->colon;
            my @normal_prereqs = @{ $rule->normal_prereqs };
            # ...
        }
    );
    $eval->set_required_target($user_makefile)
    $eval->make($goal);

=head1 DESCRIPTION

makefile AST 的运行时由 Makefile::AST::Evaluator 类实现， 用于按照 GNU make 的语义"执行"给定的 GNU make AST。 
值得一提的是，包括显隐式规则的应用在内的拓朴图的构建算法其实大部分实现在了 Makefile::AST 及其子节点类中了。 
我已将 `make -pq`, Makefile::Parser::GmakeDB, 和 Makefile::AST::Evaluator 三者串联了起来， 组装成了一个完整的 make 工具，即 pgmake-db. 
该工具可以运行基于 IPC 的 GNU make 测试集。目前已通过了 GNU make 官方测试集中 50% 以上的测试用例。 
1.3.2. 行为配置变量 
AST 执行单元 Makefile::AST::Evaluator 模块提供了若干个包变量（即静态类变量），用于提供 GNU make 官方程序通过命令行选项提供的功能。用户可以通过这些包变量对运行时环境的行为进行控制， 特别是当将运行时环境用于依赖关系图绘制、翻译等特殊目的时，需要设置 $AlwaysMake 变量为真， 以迫使运行时尽量少考虑外部环境中文件的时间戳，同时还需设置 $Question 变量， 以阻止运行时去实际执行 makefile 中的 shell 规则命令。 
$Question 
该变量对应于 GNU make 的命令行选项 -q 或者 --question，它的作用是令运行时进入所谓的“询问模式”， 即不运行任何规则命令，并且无输出。 
$AlwaysMake 
该变量对应于 GNU make 的命令行选项 -B 与 --always-make，其作用是强制重建所有规则的目标， 不根据规则的依赖描述决定是否重建目标文件。 
$Quiet 
该变量对应于 GNU make 的命令行选项 -s, --silent, 与 --quiet. 其作用是取消命令执行过程的打印。 
$JustPrint 
该变量对应于 GNU make 的命令行选项 -n, --just-print, --dry-run, 或者 --recon. 其作用是只打印出所要执行的命令，但不执行命令。 
$IgnoreErrors 
该变量对应于 GNU make 的命令行选项 -i, 或 --ignore-errors，其作用是在执行过程中忽略规则命令执行的错误。 
1.3.3. 类的触发器 
Makefile::AST::Evaluator 的 make_by_rule 方法中通过 Class::Trait 模块定义了一个名为 firing_rule 的触发器。每当 make_by_rule 方法执行到触发点时，就将上下文中的 Makefile::AST::Rule 对象和与之对应的 Makefile::AST::Command 对象传递到触发器的处理句柄中。 
用户代码正是通过向 firing_rule 触发器注册自己的消息处理句柄的方式来复用运行时的代码的。 这种方式能有效地让我的 Evaluator 代码保持整洁，同时又给用户的应用提供了很大的灵活性。 

=head1 SVN REPOSITORY

For the very latest version of this script, check out the source from

L<http://svn.openfoundry.org/makefileparser/branches/gmake-db>.

There is anonymous access to all.

=head1 AUTHOR

Agent Zhang C<< <agentzh@yahoo.cn> >>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2005-2008 by Agent Zhang (agentzh).

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<Makefile::AST>, L<Makefile::Parser::GmakeDB>,
L<makesimple>, L<Makefile::DOM>.

