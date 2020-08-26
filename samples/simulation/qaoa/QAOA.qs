namespace Microsoft.Quantum.Samples.QAOA {
    open Microsoft.Quantum.Intrinsic;
    open Microsoft.Quantum.Canon;
    open Microsoft.Quantum.Measurement;
    open Microsoft.Quantum.Convert;
    open Microsoft.Quantum.Arrays;
    open Microsoft.Quantum.Math;
    open Microsoft.Quantum.Diagnostics;

    /// # Summary
    /// This operation applies the X-rotation to each qubit. We can think of it as time 
    /// evolution induced by applying H = - \sum_i X_i for time t.
    ///
    /// # Input
    /// ## target
    /// Target qubit register
    /// ## time
    /// Time passed in evolution of X rotation
    operation DriverHamiltonian(target: Qubit[], time: Double) : Unit {
        for(qubit in target)
        {
            Rx(-2.0 * time, qubit);
        }
    }

    /// # Summary
    /// This applies the Z-rotation according to the instance Hamiltonian. 
    /// We can think of it as Hamiltonian time evolution for time t induced
    /// by the Ising Hamiltonian $\sum_ij J_ij Z_i Z_j + \sum_i h_i Z_i$.
    ///
    /// # Input
    /// ## target
    /// Qubit register that encodes the Spin values in the Ising Hamiltonian
    /// ## time
    /// Time point in evolution
    /// ## weights
    /// Ising magnetic field or "weights" encoding the constraints of our
    /// traveling Santa problem.
    /// ## coupling
    /// Ising coupling term or "penalty" encoding the constraints of our
    /// traveling Santa problem.
    operation InstanceHamiltonian(
        target: Qubit[], 
        time: Double, 
        weights: Double[], 
        coupling: Double[]
    ) : Unit {
        using (auxiliary = Qubit())
        {
            for((h, qubit) in Zip(weights, target))
            {
                Rz(2.0 * time * h, qubit);
            }
            for(i in 0..5)
            {
                for (j in i+1..5)
                {
                    CNOT(target[i], auxiliary);
                    CNOT(target[j], auxiliary);
                    Rz(2.0 * time * coupling[6 * i + j], auxiliary);
                    CNOT(target[i], auxiliary);
                    CNOT(target[j], auxiliary);
                }
            }
            Reset(auxiliary);
        }
    }

    /// # Summary
    /// Calculate Hamiltonian parameters based on the given costs and penalty
    ///
    /// # Input
    /// ## segmentCosts
    /// Cost values of each segment
    /// ## penalty
    /// Penalty for cases that don't meet constraints
    ///
    /// # Output
    /// ## weights
    /// Hamiltonian parameters or "weights" as an array where each element corresponds 
    /// to a parameter h_j for qubit state j.
    function createHamiltonianWeights(segmentCosts : Double[], penalty: Double) : Double[] {
        mutable weights = new Double[6];
        for (i in 0..5) {
            set weights w/= i <- 4.0 * penalty - 0.5 * segmentCosts[i];
        }
        return weights;
    }

    /// # Summary
    /// Calculate Hamiltonian coupling parameters based on the given penalty
    ///
    /// # Input
    /// ## penalty
    /// Penalty for cases that don't meet constraints
    ///
    /// # Output
    /// ## coupling
    /// Hamiltonian coupling parameters as an array, where each element corresponds
    /// to a parameter J_ij between qubit states i and j.
    function createHamiltonianCouplings(penalty: Double) : Double[] {
        // Calculate Hamiltonian coupling parameters based on the given costs and penalty
        mutable coupling = new Double[36];

        // Most elements of J_ij equal 2*penalty, so set all elements to this value, 
        // then overwrite the exceptions
        for (i in 0..35)
        {
            set coupling w/= i <- 2.0 * penalty;
        }
        set coupling w/= 2 <- penalty;
        set coupling w/= 9 <- penalty;
        set coupling w/= 29 <- penalty;

        return coupling;
    }
    
    /// # Summary
    /// Perform the QAOA algorithm for this Ising Hamiltonian
    ///
    /// # Input
    /// ## weights
    /// Instance Hamiltonian parameters or "weights" as an array where each element corresponds to a 
    /// parameter h_j for qubit state j.
    /// ## couplings
    /// Instance Hamiltonian coupling parameters as an array, where each element corresponds
    /// to a parameter J_ij between qubit states i and j.
    /// ## timeX
    /// Time evolution for PauliX operations
    /// ## timeZ
    /// Time evolution for PauliX operations
    operation PerformQAOA(weights : Double[], couplings : Double[], timeX : Double[], timeZ : Double[]) : Bool[] {
        EqualityFactI(Length(timeX), Length(timeZ), "timeZ and timeX are not the same length");

        // Run the QAOA circuit
        mutable result = new Bool[6];
        using (x = Qubit[6])
        {
            ApplyToEach(H, x); // prepare the uniform distribution
            for ((tz, tx) in Zip(timeZ, timeX))
            {
                InstanceHamiltonian(x, tz, weights, couplings); // do Exp(-i H_C tz)
                DriverHamiltonian(x, tx); // do Exp(-i H_0 tx)
            }
            set result = ResultArrayAsBoolArray(MultiM(x)); // measure in the computational basis
            ResetAll(x);
        }
        return result;
    }

    /// # Summary
    /// Calculate the total cost for the given result.
    ///
    /// # Input
    /// ## segmentCosts
    /// Array of costs per segment
    /// ## usedSegments
    /// Array of which segments are used
    ///
    /// # Output
    /// ## finalCost
    /// Calculated cost of given path
    function calculateCost(segmentCosts : Double[], usedSegments : Bool[]) : Double {
        mutable finalCost = 0.0;
        for ((cost, segment) in Zip(segmentCosts, usedSegments)) {
            set finalCost = segment ? finalCost + cost | finalCost;
        }
        return finalCost;
    }

    /// # Summary
    /// Final check to determine if the used segments satisfy our known constraints.
    /// Returns true or false.
    ///
    /// # Input
    /// ## usedSegments
    /// Array of which segments were used
    function determineSatisfactory(usedSegments : Bool[]) : Bool {
        mutable HammingWeight = 0;
        for (segment in usedSegments)
        {
            set HammingWeight = segment ? HammingWeight + 1 | HammingWeight;
        }
        if (HammingWeight != 4 
            or usedSegments[0] != usedSegments[2] 
            or usedSegments[1] != usedSegments[3] 
            or usedSegments[4] != usedSegments[5]) {
            return false;
        }
        return true;
    }

    /// # Summary
    /// Run QAOA for a given number of trails. Based on the Traveling Santa
    /// Problem outlined here: http://quantumalgorithmzoo.org/traveling_santa/.
    /// Reports on the best itinerary for the Traveling Santa Problem and how 
    /// many of the runs resulted in the answer. This should typically return 
    /// the optimal solution roughly 71% of the time.
    /// 
    /// # Input
    /// ## numTrials
    /// Number of trials to run the QAOA algorithm for.
    @EntryPoint()
    operation RunQAOATrials(numTrials : Int) : Unit {
        let penalty = 20.0;
        let segmentCosts = [4.70, 9.09, 9.03, 5.70, 8.02, 1.71];
        let timeX = [0.619193, 0.742566, 0.060035, -1.568955, 0.045490];
        let timeZ = [3.182203, -1.139045, 0.221082, 0.537753, -0.417222];
        let limit = 1E-6;

        mutable bestCost = 100.0 * penalty;
        mutable bestItinerary = [false, false, false, false, false];
        mutable successNumber = 0;

        let weights = createHamiltonianWeights(segmentCosts, penalty);
        let couplings = createHamiltonianCouplings(penalty);

        for (trial in 0..numTrials)
        {
            let result = PerformQAOA(weights, couplings, timeX, timeZ);
            let cost = calculateCost(segmentCosts, result);
            let sat = determineSatisfactory(result);
            Message($"result = {result}, cost = {cost}, satisfactory = {sat}");
            if (sat) {
                if (cost < bestCost - limit) {
                    // New best cost found - update
                    set bestCost = cost;
                    set bestItinerary = result;
                    set successNumber = 1;
                } elif (AbsD(cost - bestCost) < limit) {
                    set successNumber += 1;
                }
            }
        }
        let runPercentage = IntAsDouble(successNumber) * 100.0 / 20.0;
        Message("Simulation is complete\n");
        Message($"Best itinerary found: {bestItinerary}, cost = {bestCost}");
        Message($"{runPercentage}% of runs found the best itinerary\n");
    }
}
