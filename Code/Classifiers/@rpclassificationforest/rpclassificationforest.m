classdef rpclassificationforest
    
    properties
        oobidx = {}; %indices of out of bag samples for each tree
        Tree = {};  %classification trees contained in the ensemble
        nTrees = []; %number of trees in the ensemble
        classname;
        RandomForest;
        Robust;
%         NumVars = [];
        priors = [];
        rotmat = [];
    end
    
    methods
        function forest = rpclassificationforest(nTrees,X,Y,varargin)
            %class contstructor for RandomerForest object
            %
            %nTrees: number of trees in ensemble
            %
            %X: n x d matrix where n is number of samples and d is
            %
            %number of dimensions (predictor variables)
            %
            %Y: n x 1 cell string of class labels
            %
            %Optional Arguments:
                %nvartosample: if 'RandomForest' is true, then this is the
                %number of variables subsampled when splitting. Otherwise,
                %this is the dimension of the subspace randomly projected
                %into
                %
                %s: s a parameter that specifies the sparsity of the random
                %projection matrix. Sparsity is computed as 1/(2*s). Only
                %used if sparsemethod is set to 'dense'
                %
                %mdiff: string 'all', 'node' or 'off'. Specifying 'all' or
                %'node' allows the full-sample or node-sample
                %class-conditional differences in means to be sampled as
                %projections
                %
                %sparsemethod: string specifying the method for sampling
                %the random projection matrix. Options are 'dense' (dense
                %nonzeros sampled from [-1,1]), 'sparse' (nonzeros
                %sampled from {-1,1}), and 'frc' (Breiman's Forest-RC). For
                %dense, sparisty is controlled by the parameter 's'.
                %
                %RandomForest: logical true or false (default). Setting to
                %true performs traditional random forest
                %
                %Robust: logical true or false (default). Setting to true
                %passes the data to marginal ranks prior to any computing
                %
                %NWorkers: number of workers for parallel computing
                %(default = 1)
                %
                %rotate: logical true or false (default). Setting to true
                %uniformly randomly rotates the data for each tree prior to
                %fitting
                %
                %p: probability of sampling each of the K-1 mean difference
                %vectors, where K is the number of classes
            %
            %Example:
            %
            %Train a RerF classifier consisting of 500 trees using dense random projections with
            %sparsity = 2/3 (s = 3) and allowing mean difference
            %projections to be sampled. The 'node' option computes sample
            %means using only samples at the current split node. Connect to
            %6 workers, which allows 6 trees to be constructed in parallel.
            %Compute out of bag error achieved at the final ('last') tree.
            %
            %rerf = rpclassificationforest(500,X,Y,'s',3,'mdiff','node','NWorkers',6);
            %
            %err = oobpredict(rerf,X,Y,'last');
                
            if ~iscell(Y)
                Y = cellstr(num2str(Y));
            end
            forest.classname = unique(Y);
            forest = growTrees(forest,nTrees,X,Y,varargin{:});
        end     %class constructor
        
        function forest = growTrees(forest,nTrees,X,Y,varargin)
            okargs =   {'priorprob' 'cost'    'splitcriterion'  'splitmin'...
                        'minparent' 'minleaf'   'nvartosample'...
                        'mergeleaves'   'categorical' 'prune' 'method' ...
                        'qetoler'   'names'   'weights' 'surrogate'...
                        'skipchecks'    'stream'    'fboot'...
                        'SampleWithReplacement' 's' 'mdiff' 'sparsemethod'...
                        'RandomForest'   'Robust'   'NWorkers'  'Stratified'...
                        'nmix'  'rotate'    'p'};
            defaults = {[]  []  'gdi'   []  []  1   ceil(size(X,2)^(2/3))...
                        'off'    []  'off'    'classification'  1e-6    {}...
                        []  'off'   false  []  1    true   1/size(X,2)    'off'   'sparse'...
                        false false 1   true   2   false  []};
            [Prior,Cost,Criterion,splitmin,minparent,minleaf,...
                nvartosample,Merge,categ,Prune,Method,qetoler,names,W,...
                surrogate,skipchecks,Stream,fboot,...
                SampleWithReplacement,s,mdiff,sparsemethod,RandomForest,...
                Robust,NWorkers,Stratified,nmix,rotate,p,~,extra] = ...
                internal.stats.parseArgs(okargs,defaults,varargin{:});
            
            %Convert to double if not already
            if ~isa(X,'double')
                X = double(X);
            end
            
            if Robust
                %X = passtorank(X);
                X = tiedrank(X);
                forest.Robust = true;
            else
                forest.Robust = false;
            end
            
            [n,d] = size(X);
            
            %Check sparsity
            if s < 1/d
                s = 1/d;
            elseif s > 1
                s = 1;
            end
            
            nclasses = length(forest.classname);
            priors = NaN(1,nclasses);
            for c = 1:nclasses
                priors(c) = sum(strcmp(Y,forest.classname(c)))/length(Y);
            end
            nboot = ceil(fboot*length(Y));
            Tree = cell(nTrees,1);
            oobidx = cell(nTrees,1);
            sampleidx = 1:length(Y);
            
            RR = zeros(d,d,nTrees);
            
            poolobj = gcp('nocreate');
            if isempty(poolobj);
                parpool('local',NWorkers,'IdleTimeout',360);
            end
            
            parfor i = 1:nTrees

                %Rotate data?
                if rotate
                    RR(:,:,i) = random_rotation(d);
                    Xtree = X*RR(:,:,i);
                else
                    Xtree = X;
                end
                
                go = true;
                if Stratified
                    while go
                        ibidx = []
                        for c = 1:nclasses
                            idx = find(strcmp(forest.classname{c},Y));
                            if length(idx) > 1
                                ibidx = cat(2,ibidx,transpose(randsample(idx,ceil(fboot*length(idx)),SampleWithReplacement)));
                            else
                                ibidx(end+1) = idx;
                            end
                        end
                        oobidx{i} = setdiff(sampleidx,ibidx);
                        go = isempty(oobidx{i});
                    end
                else
                    while go
                        ibidx = randsample(sampleidx,nboot,SampleWithReplacement);
                        oobidx{i} = setdiff(sampleidx,ibidx);
                        go = isempty(oobidx{i});
                    end
                end
                
                if ~RandomForest
                    Tree{i} = rpclassregtree(Xtree(ibidx,:),Y(ibidx,:),...
                        'priorprob',Prior,'cost',Cost,'splitcriterion',...
                        Criterion,'splitmin',splitmin,'minparent',...
                        minparent,'minleaf',minleaf,'nvartosample',...
                        nvartosample,'mergeleaves',Merge,'categorical',...
                        categ,'prune',Prune,'method',Method,'qetoler',...
                        qetoler,'names',names,'weights',W,'surrogate',...
                        surrogate,'skipchecks',skipchecks,'stream',Stream,...
                        's',s,'mdiff',mdiff,'sparsemethod',sparsemethod,'nmix',nmix,...
                        'p',p);
                else
                    Tree{i} = classregtree2(Xtree(ibidx,:),Y(ibidx,:),...
                        'priorprob',Prior,'cost',Cost,'splitcriterion',...
                        Criterion,'splitmin',splitmin,'minparent',...
                        minparent,'minleaf',minleaf,'nvartosample',...
                        nvartosample,'mergeleaves',Merge,'categorical',...
                        categ,'prune',Prune,'method',Method,'qetoler',...
                        qetoler,'names',names,'weights',W,'surrogate',...
                        surrogate,'skipchecks',skipchecks,'stream',Stream);
                end  
            end     %parallel loop over i
            
            %Compute interpretability as total number of variables split on
%             NumVars = NaN(1,nTrees);
%             if RandomForest
%                 for i = 1:nTrees
%                     NumVars(i) = sum(Tree{i}.var~=0);
%                 end
%             else
%                 for i = 1:nTrees
%                     internalnodes = transpose(Tree{i}.node(Tree{i}.var ~= 0));
%                     TreeVars = zeros(1,length(Tree{i}.node));
%                     for nd = internalnodes
%                         if ~Tree{i}.isdelta(nd)
%                             TreeVars(nd) = nnz(Tree{i}.rpm{nd});
%                         end
%                     end
%                     NumVars(i) = sum(TreeVars);
%                 end
%             end                        
            forest.Tree = Tree;
            forest.oobidx = oobidx;
            forest.nTrees = length(forest.Tree);
            forest.RandomForest = RandomForest;
%             forest.NumVars = NumVars;
            forest.priors = priors;
            if rotate
                forest.rotmat = RR;
            end
        end     %function rpclassificationforest
        
        function [err,varargout] = oobpredict(forest,X,Y,treenum)
            if nargin == 3
                treenum = 'last';
            end
            
            %Convert to double if not already
            if ~isa(X,'double')
                X = double(X);
            end
            
            if forest.Robust
                %X = passtorank(X);
                X = tiedrank(X);
            end
            nrows = size(X,1);
            predmat = NaN(nrows,forest.nTrees);
            predcell = cell(nrows,forest.nTrees);
            OOBIndices = forest.oobidx;
            trees = forest.Tree;
            Labels = forest.classname;
            rotate = ~isempty(forest.rotmat);
            if ~forest.RandomForest
                parfor i = 1:forest.nTrees
                    if rotate
                        Xtree = X*forest.rotmat(:,:,i);
                    else
                        Xtree = X;
                    end
                    pred_i = num2cell(NaN(nrows,1));
                    pred_i(OOBIndices{i}) = rptreepredict(trees{i},Xtree(OOBIndices{i},:));
                    predcell(:,i) = pred_i;
                end
            else
                parfor i = 1:forest.nTrees
                    if rotate
                        Xtree = X*forest.rotmat(:,:,i);
                    else
                        Xtree = X;
                    end
                    pred_i = num2cell(NaN(nrows,1));
                    pred_i(OOBIndices{i}) = eval(trees{i},Xtree(OOBIndices{i},:));
                    predcell(:,i) = pred_i;
                end
            end
            for j = 1:length(forest.classname)
                predmat(strcmp(predcell,Labels{j})) = j;
            end
            if strcmp(treenum,'every')
                err = NaN(forest.nTrees,1);
                parfor i = 1:forest.nTrees
                    ensemblepredictions = mode(predmat(:,1:i),2);
                    missing = isnan(ensemblepredictions);
                    predictions = Labels(ensemblepredictions(~missing));
                    wrong = ~strcmp(predictions,Y(~missing));
                    err(i) = mean(wrong);
                end
            else
                ensemblepredictions = mode(predmat,2);
                missing = isnan(ensemblepredictions);
                predictions = Labels(ensemblepredictions(~missing));
                wrong = ~strcmp(predictions,Y(~missing));
                err = mean(wrong);       
            end
            %if length(unique(Y)) == 2
            %    pos = num2str(max(str2num(char(Y))));
            %    neg = num2str(min(str2num(char(Y))));
                
                %varargout{1} = sum(strcmp(predictions(strcmp(pos,Y)),Y(~missing & strcmp(pos,Y))))/sum(strcmp(pos,Y));  %sensitivity
                %varargout{2} = sum(strcmp(predictions(strcmp(pos,Y)),Y(~missing & strcmp(pos,Y))))/sum(strcmp(pos,predictions));    %ppv
                %varargout{3} = sum(strcmp(predictions(strcmp(neg,Y)),Y(~missing & strcmp(neg,Y))))/sum(strcmp(neg,Y));  %specificity
                %varargout{4} = sum(strcmp(predictions(strcmp(neg,Y)),Y(~missing & strcmp(neg,Y))))/sum(strcmp(neg,predictions));    %npv
                %varargout{1} = sum(strcmp(predictions(strcmp(pos,Y)),Y(~missing & strcmp(pos,Y)))); %tp
                %varargout{2} = sum(~strcmp(predictions(strcmp(pos,Y)),Y(~missing & strcmp(pos,Y))));    %fn
                %varargout{3} = sum(strcmp(predictions(strcmp(neg,Y)),Y(~missing & strcmp(neg,Y)))); %tn
                %varargout{4} = sum(~strcmp(predictions(strcmp(neg,Y)),Y(~missing & strcmp(neg,Y))));    %fp
            %end
        end     %function oobpredict
        
        function scores = rerf_oob_classprob(forest,X,treenum)
            if nargin == 2
                treenum = 'last';
            end
            
            %Convert to double if not already
            if ~isa(X,'double')
                X = double(X);
            end
            
            if forest.Robust
                X = tiedrank(X);
            end
            nrows = size(X,1);
            
            Labels = forest.classname;
            nclasses = length(Labels);
            scoremat = NaN(nrows,nclasses,forest.nTrees);
            OOBIndices = forest.oobidx;
            trees = forest.Tree;
            if ~forest.RandomForest
                parfor i = 1:forest.nTrees
                    score_i = NaN(nrows,nclasses);
                    score_i(OOBIndices{i},:) = rpclassprob(trees{i},X(OOBIndices{i},:))
                    scoremat(:,:,i) = score_i;
                end
            else
                parfor i = 1:forest.nTrees
                    score_i = NaN(nrows,nclasses,1);
                    score_i(OOBIndices{i},:,1) = rfclassprob(trees{i},X(OOBIndices{i},:));
                    scoremat(:,:,i) = score_i;
                end
            end
            if strcmp(treenum,'every')
                scores = NaN(size(scoremat));
                parfor i = 1:forest.nTrees
                    score_i = nanmean(scoremat(:,:,1:i),3);
                    missing = any(isnan(score_i),2);
                    %fprintf('%d\n',size(score_i(missing,:)))
                    %fprintf('%d\n',size(repmat(forest.priors,length(missing),1)))
                    score_i(missing,:) = repmat(forest.priors,sum(missing),1);
                    scores(:,:,i) = score_i;
                end
            else
                scores = nanmean(scoremat,3);
                missing = any(isnan(scores),2);
                scores(missing,:) = repmat(forest.priors,sum(missing),1);
            end
        end     %function rerf_oob_classprob
        
        function scores = rerf_classprob(forest,Xtest,treenum,varargin)
            if nargin == 2
                treenum = 'last';
            end
            
            if nargin == 4;
                Xtrain = varargin{1};
                if ~isa(Xtrain,'double')
                    Xtrain = double(Xtrain);
                end
            end
            
            if forest.Robust
                if nargin < 4
                    error('Training data is required as third input argument for predicting')
                end
                Xtest = interpolate_rank(Xtrain,Xtest);
            end
            
            %Convert to double if not already
            if ~isa(Xtest,'double')
                Xtest = double(Xtest);
            end
            
            nrows = size(Xtest,1);
            
            Labels = forest.classname;
            nclasses = length(Labels);
            scoremat = NaN(nrows,nclasses,forest.nTrees);
            trees = forest.Tree;
            rotate = ~isempty(forest.rotmat);
            if ~forest.RandomForest
                parfor i = 1:forest.nTrees
                    if rotate
                        Xtree = Xtest*forest.rotmat(:,:,i);
                    else
                        Xtree = Xtest;
                    end
                    score_i = rpclassprob(trees{i},Xtree)
                    scoremat(:,:,i) = score_i;
                end
            else
                parfor i = 1:forest.nTrees
                    if rotate
                        Xtree = Xtest*forest.rotmat(:,:,i);
                    else
                        Xtree = Xtest;
                    end
                    score_i = rfclassprob(trees{i},Xtree);
                    scoremat(:,:,i) = score_i;
                end
            end
            if strcmp(treenum,'every')
                scores = NaN(size(scoremat));
                parfor i = 1:forest.nTrees
                    score_i = mean(scoremat(:,:,1:i),3);
                    scores(:,:,i) = score_i;
                end
            else
                scores = mean(scoremat,3);
            end
        end     %function rerf_classprob
        
        function Y = predict(forest,X,varargin)
                        
            %Convert to double if not already
            if ~isa(X,'double')
                X = double(X);
            end
            
            if nargin == 3;
                Xtrain = varargin{1};
                if ~isa(Xtrain,'double')
                    Xtrain = double(Xtrain);
                end
            end
            
            if forest.Robust
                if nargin < 3
                    error('Training data is required as third input argument for predicting')
                end
                X = interpolate_rank(Xtrain,X);
            end
            n = size(X,1);
            predmat = NaN(n,forest.nTrees);
            YTree = cell(n,forest.nTrees);
            Tree = forest.Tree;
            rotate = ~isempty(forest.rotmat);
            if ~forest.RandomForest
                parfor i = 1:forest.nTrees
                    if rotate
                        Xtree = X*forest.rotmat(:,:,i);
                    else
                        Xtree = X;
                    end
                    YTree(:,i) = rptreepredict(Tree{i},Xtree);
                end
            else
                parfor i = 1:forest.nTrees
                    if rotate
                        Xtree = X*forest.rotmat(:,:,i);
                    else
                        Xtree = X;
                    end
                    YTree(:,i) = eval(Tree{i},Xtree);
                end
            end
            Labels = forest.classname;
            for j = 1:length(Labels)
                predmat(strcmp(YTree,Labels{j})) = j;
            end
            ensemblepredictions = mode(predmat,2);
            missing = isnan(ensemblepredictions);
            Y = Labels(ensemblepredictions(~missing));
        end     %function predict
        
        function sp = db_sparsity(forest)
            %sparsity of decision boundary computed as sum #variables used
            %over all nodes
            
            sp = 0;
            for i = 1:forest.nTrees
                Tree = forest.Tree{i};
                if ~forest.RandomForest
                    internalnodes = Tree.node(Tree.var~=0);
                    for node = internalnodes'
                        sp = sp + sum(Tree.rpm{node}~=0);
                    end
                else
                    sp = sp + sum(Tree.var~=0);
                end
            end
        end
        
        function [predcell,err] = oobpredict2(forest,X,Y)
            if nargin == 3
                OutSpec = 'average';
            end
            
            %Convert to double if not already
            if ~isa(X,'double')
                X = double(X);
            end
            
            if forest.Robust
                %X = passtorank(X);
                X = tiedrank(X);
            end
            nrows = size(X,1);
            predmat = NaN(nrows,forest.nTrees);
            predcell = cell(nrows,forest.nTrees);
            err = NaN(1,forest.nTrees);
            OOBIndices = forest.oobidx;
            trees = forest.Tree;
            Labels = forest.classname;
            rotate = ~isempty(forest.rotmat);
            if ~forest.RandomForest
                parfor i = 1:forest.nTrees
                    if rotate
                        Xtree = X*forest.rotmat(:,:,i);
                    else
                        Xtree = X;
                    end
                    pred_i = cell(nrows,1);
                    pred_i(OOBIndices{i}) = rptreepredict(trees{i},Xtree(OOBIndices{i},:));
                    predcell(:,i) = pred_i;
                    err(i) = sum(~strcmp(pred_i(OOBIndices{i}),Y(OOBIndices{i})))/length(OOBIndices{i});
                end
            else
                parfor i = 1:forest.nTrees
                    if rotate
                        Xtree = X*forest.rotmat(:,:,i);
                    else
                        Xtree = X;
                    end
                    pred_i = cell(nrows,1);
                    pred_i(OOBIndices{i}) = eval(trees{i},Xtree(OOBIndices{i},:));
                    predcell(:,i) = pred_i;
                    err(i) = sum(~strcmp(pred_i(OOBIndices{i}),Y(OOBIndices{i})))/length(OOBIndices{i});
                end
            end
        end     %function oobpredict2       
    end     %methods
end     %classdef
